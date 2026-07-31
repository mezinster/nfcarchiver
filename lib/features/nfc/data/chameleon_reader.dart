import 'dart:async';
import 'dart:typed_data';

import '../../../core/chameleon/chameleon_device.dart';
import '../../../core/constants/nfar_format.dart';
import '../../../core/log/logger.dart';
import '../../../core/mifare/card_layout.dart';
import '../../../core/models/chunk.dart';
import '../../../core/models/nfc_tag_info.dart';
import '../../../core/nfc/ndef_bytes.dart';
import '../../../core/nfc/type2.dart';
import '../domain/card_reader.dart';

/// A Chameleon Ultra behind the [CardReader] seam.
///
/// The Chameleon is **pull-based** — you poll it — while the app is
/// callback/session based, because `nfc_manager` wraps Android's reader-mode
/// callbacks. This class adapts one to the other by polling `scanTag()` and
/// firing the same callbacks reader mode would, so `ArchiveNotifier` and
/// `RestoreNotifier` see no difference at all.
class ChameleonReader implements CardReader {
  ChameleonReader(
    this._device, {
    Duration pollInterval = const Duration(milliseconds: 300),
  }) : _pollInterval = pollInterval;

  final ChameleonDevice _device;
  final Duration _pollInterval;

  bool _sessionActive = false;
  DateTime? _lastWriteAt;

  /// Bumped by every session start. A poll loop exits as soon as its own
  /// generation is stale, so starting a session while one runs SUPERSEDES it
  /// instead of adding a second loop.
  ///
  /// Without this, a caller that restarts on error (scan_screen does exactly
  /// that) spawns loop after loop, all racing for a device that permits one
  /// command in flight — which is how the first hardware scan hung the app.
  /// The same ownership rule as readerEpoch in the web app's device.ts.
  int _generation = 0;

  /// The UID resting on the reader right now.
  ///
  /// A card left in the field would otherwise be re-read every poll and flood
  /// the restore loop with duplicates of one chunk. Cleared when the field goes
  /// empty, so lifting and re-presenting the same card reads it again.
  ///
  /// Deliberately NOT cleared when a session starts. The restore screen
  /// restarts the session after every successful read — a phone-NFC habit,
  /// where one tap is one session — and clearing here made a resting card look
  /// new each time, so it was re-read about once a second forever. Observed on
  /// hardware. It IS cleared on [connect], so a card already resting when the
  /// user connects is still picked up.
  String? _currentUid;

  /// Visible for tests: whether a session loop is running.
  bool get isSessionActive => _sessionActive;

  @override
  String get name => 'chameleon-ble';

  /// A Chameleon gives raw ISO 14443-A access, which is what makes the card
  /// inspector possible at all.
  @override
  bool get supportsRawAccess => true;

  @override
  bool get isInWriteCooldown {
    final at = _lastWriteAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 2);
  }

  @override
  void clearWriteCooldown() => _lastWriteAt = null;

  @override
  Future<void> connect() async {
    _currentUid = null;
    await _device.connect();
  }

  @override
  Future<void> disconnect() async {
    _sessionActive = false;
    await _device.disconnect();
  }

  /// Nothing to query: a Chameleon's capabilities do not depend on the phone.
  @override
  Future<void> initCapabilities() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    // Accepted and ignored: it exists for iOS's system NFC sheet, which a
    // Chameleon has no equivalent of. Conditionalising the interface for one
    // platform's UI would be worse than one unused parameter.
    String alertMessage = '',
  }) async {
    final gen = ++_generation;
    _sessionActive = true;
    log.info('reader', 'Read session started', {'gen': gen});

    unawaited(_pollLoop(gen, (tag) async {
      final info = _tagInfo(tag);
      log.info('reader', 'Tag discovered', {
        'uid': info.identifier,
        'sak': '0x${tag.sak.toRadixString(16).padLeft(2, '0')}',
      });
      onTagDiscovered?.call(info);
      final bytes = await _readChunkBytes(tag);
      if (bytes == null) {
        log.debug('reader', 'Card holds no NFAR chunk — skipped');
        return; // blank card — normal during a restore
      }
      log.info('reader', 'Chunk read', {'bytes': bytes.length});
      onChunkRead(Chunk.fromBytes(bytes), info);
    }, onError));

    return () {
      // Only the session that owns this closure may stop the loop; a stale
      // closure must not cancel the run that replaced it.
      if (gen == _generation) _sessionActive = false;
    };
  }

  @override
  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(String message) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)?
        onTagTooSmall,
    void Function(String tappedMedium, String configuredMedium,
            NfcTagInfo? tagInfo)?
        onTagTypeMismatch,
    String alertMessage = '',
  }) async {
    final gen = ++_generation;
    _sessionActive = true;
    // A write session DOES clear it: the user is presenting cards to be
    // written, and the card resting from a previous read must not be skipped.
    _currentUid = null;
    final bytes = chunk.toBytes();
    log.info('reader', 'Write session started', {'bytes': bytes.length, 'gen': gen});

    unawaited(_pollLoop(gen, (tag) async {
      final info = _tagInfo(tag);
      if (tag.sak == 0x08) {
        if (bytes.length > cardCapacityBytes) {
          // Rejected before a single block is written: a partial write would
          // leave the card holding a chunk that can never be assembled.
          onTagTooSmall?.call(bytes.length, cardCapacityBytes, info);
          onError('Chunk is ${bytes.length} B; a Mifare Classic 1K holds '
              '$cardCapacityBytes B');
          _sessionActive = false;
          return;
        }
        await _writeClassic(bytes);
      } else {
        await _writeNtag(bytes);
      }
      _lastWriteAt = DateTime.now();
      log.info('reader', 'Write complete and verified', {'uid': info.identifier});
      onSuccess(info);
      _sessionActive = false;
    }, onError));

    return () {
      if (gen == _generation) _sessionActive = false;
    };
  }

  @override
  Future<NfcReadResult> readTag({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final completer = Completer<NfcReadResult>();
    void Function()? stop;
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      stop?.call();
      completer.complete(const NfcReadError(message: 'Timeout waiting for a card'));
    });

    stop = await startReadSession(
      onChunkRead: (chunk, info) {
        timer.cancel();
        if (completer.isCompleted) return;
        stop?.call();
        completer.complete(NfcReadSuccess(tagInfo: info, data: chunk.toBytes()));
      },
      onError: (message) {
        timer.cancel();
        if (completer.isCompleted) return;
        stop?.call();
        completer.complete(NfcReadError(message: message));
      },
    );
    return completer.future;
  }

  @override
  Future<NfcWriteResult> writeTag({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final completer = Completer<NfcWriteResult>();
    void Function()? stop;
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      stop?.call();
      completer.complete(const NfcWriteError(message: 'Timeout waiting for a card'));
    });

    stop = await startWriteSession(
      chunk: chunk,
      configuredTagType: configuredTagType,
      onSuccess: (info) {
        timer.cancel();
        if (completer.isCompleted) return;
        stop?.call();
        completer.complete(
          NfcWriteSuccess(tagInfo: info, bytesWritten: chunk.toBytes().length),
        );
      },
      onError: (message) {
        timer.cancel();
        if (completer.isCompleted) return;
        stop?.call();
        completer.complete(NfcWriteError(message: message));
      },
    );
    return completer.future;
  }

  @override
  void stopSession({String? message}) => _sessionActive = false;

  // ---- internals ------------------------------------------------------------

  Future<void> _pollLoop(
    int gen,
    Future<void> Function(ScannedTag tag) onTag,
    void Function(String message) onError,
  ) async {
    while (_sessionActive && gen == _generation) {
      final iterationStart = DateTime.now();
      try {
        final tag = await _device.scanTag();
        if (tag == null) {
          // Field empty: forget the resting card so re-presenting it counts as
          // a fresh tap.
          _currentUid = null;
        } else {
          final uid = _uidHex(tag.uid);
          if (uid != _currentUid) {
            _currentUid = uid;
            if (!isInWriteCooldown) await onTag(tag);
          }
        }
      } on CardAuthException catch (e) {
        log.warn('reader', 'Foreign card — session continues', {'why': e.message});
        // A foreign card — a hotel key or transit card on the reader. Report
        // it, but NEVER end the session: aborting a restore because one wrong
        // card was tapped would be a worse bug than the one being avoided.
        onError(e.message);
      } catch (e) {
        log.error('reader', 'Poll iteration failed', {'error': e.toString()});
        onError(e.toString());
      }
      // Paced on EVERY path, including errors. A reader that fails instantly
      // would otherwise spin the loop as fast as the event loop allows, which
      // is precisely how the web app's Web NFC scan froze the browser.
      await _paceFrom(iterationStart);
    }
    log.debug('reader', 'Poll loop ended', {'gen': gen});
  }

  Future<void> _paceFrom(DateTime start) async {
    final elapsed = DateTime.now().difference(start);
    final remaining = _pollInterval - elapsed;
    await Future<void>.delayed(
      remaining > Duration.zero ? remaining : Duration.zero,
    );
  }

  /// The chunk on the presented card, or null if it holds none.
  Future<Uint8List?> _readChunkBytes(ScannedTag tag) async {
    if (tag.sak == 0x08) return _readClassic();
    if (tag.sak == 0x00) return _readNtag();
    throw UnsupportedTagException(
      'Unsupported tag (SAK 0x${tag.sak.toRadixString(16).padLeft(2, '0')})',
    );
  }

  Future<Uint8List?> _readClassic() async {
    final first = await _readBlockStrict(usableBlockIndexes[0]);
    if (!firstBlockIsNfar(first)) return null;
    final second = await _readBlockStrict(usableBlockIndexes[1]);
    final header = Uint8List(2 * blockSize)
      ..setRange(0, blockSize, first)
      ..setRange(blockSize, 2 * blockSize, second);

    final total = nfarTotalLength(header);
    final blockCount = (total + blockSize - 1) ~/ blockSize;
    final out = Uint8List(blockCount * blockSize)
      ..setRange(0, blockSize, first)
      ..setRange(blockSize, 2 * blockSize, second);
    for (var i = 2; i < blockCount; i++) {
      out.setRange(
        i * blockSize,
        (i + 1) * blockSize,
        await _readBlockStrict(usableBlockIndexes[i]),
      );
    }
    return Uint8List.sublistView(out, 0, total);
  }

  /// Every read goes through here: a short response is a marginal RF read, not
  /// card content. Treating it as zero-padded data would report a weakly
  /// coupled card as holding no chunk, which is false.
  Future<Uint8List> _readBlockStrict(int block) async {
    final data = await _device.readBlock(block, factoryKeyA);
    if (data.length != blockSize) {
      throw CardReadException(
        'Short read on block $block: got ${data.length} of $blockSize bytes',
      );
    }
    return data;
  }

  Future<Uint8List?> _readNtag() async {
    // Read enough pages to cover the TLV header, then the whole declared area.
    final memory = <int>[];
    for (var page = ndefStartPage; page < ndefStartPage + 64; page += 4) {
      final resp = await _device.transceive14a(
        Uint8List.fromList([0x30, page]),
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: true,
      );
      if (resp.isEmpty) break;
      memory.addAll(resp);
      try {
        return decodeNdefMime(readType2Ndef(Uint8List.fromList(memory)));
      } on NdefFormatException {
        // Not yet enough bytes for a complete TLV — keep reading.
        continue;
      }
    }
    return null;
  }

  Future<void> _writeClassic(Uint8List bytes) async {
    final writes = chunkToBlocks(bytes);
    log.info('reader', 'Writing blocks', {
      'count': writes.length,
      'blocks': writes.map((w) => w.block).join(','),
    });
    for (final w in writes) {
      await _device.writeBlock(w.block, factoryKeyA, w.data);
      log.debug('reader', 'Block written', {'block': w.block});
    }
    // Verified by reading back, exactly as the web app's Chameleon transport
    // does — a write that reports success but did not land is the worst
    // possible outcome for an archive.
    log.info('reader', 'Verifying by read-back');
    for (final w in writes) {
      final back = await _readBlockStrict(w.block);
      for (var i = 0; i < blockSize; i++) {
        if (back[i] != w.data[i]) {
          log.error('reader', 'Verification failed', {
            'block': w.block,
            'wrote': hexDump(w.data),
            'read': hexDump(back),
          });
          throw CardReadException(
            'Verification failed on block ${w.block}: read-back does not match',
          );
        }
      }
    }
  }

  Future<void> _writeNtag(Uint8List bytes) async {
    final memory = wrapType2Tlv(encodeNdefMime(bytes));
    var page = ndefStartPage;
    for (var i = 0; i < memory.length; i += 4) {
      final end = (i + 4).clamp(0, memory.length);
      final pageBytes = Uint8List(4)
        ..setRange(0, end - i, Uint8List.sublistView(memory, i, end));
      await _device.transceive14a(
        Uint8List.fromList([0xA2, page, ...pageBytes]),
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: true,
      );
      page++;
    }
  }

  NfcTagInfo _tagInfo(ScannedTag tag) => NfcTagInfo(
        identifier: _uidHex(tag.uid),
        capacity: tag.sak == 0x08 ? cardCapacityBytes : 0,
        isWritable: true,
        isNdefCapable: tag.sak == 0x00,
        tagType: tag.sak == 0x08 ? NfcTagType.mifareClassic1k : null,
        technologies: const ['chameleon'],
      );

  static String _uidHex(Uint8List uid) =>
      uid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
