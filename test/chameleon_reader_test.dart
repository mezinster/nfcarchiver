import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/features/nfc/data/chameleon_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';

import 'support/fake_chameleon_device.dart';
import 'support/helpers.dart';

/// Put a real NFAR chunk on the fake Classic card, laid out the way the app
/// writes it.
void _writeChunkToCard(FakeChameleonDevice dev, Uint8List bytes) {
  for (final w in chunkToBlocks(bytes)) {
    dev.setBlock(w.block, w.data);
  }
}

ChameleonReader _reader(FakeChameleonDevice dev, {bool allow4k = false}) =>
    ChameleonReader(dev, pollInterval: Duration.zero, allow4k: () => allow4k);

void main() {
  test('ChameleonReader is a CardReader that supports raw access', () {
    final r = _reader(FakeChameleonDevice.classic1k());
    expect(r, isA<CardReader>());
    expect(r.name, 'chameleon-ble');
    expect(r.supportsRawAccess, isTrue,
        reason: 'this is what gates the card inspector');
  });

  test('a read session delivers the chunk on the card', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    Chunk? got;
    final stop = await _reader(dev).startReadSession(
      onChunkRead: (c, _) => got = c,
      onError: (_) {},
    );
    await pumpUntil(() => got != null);
    stop();

    expect(got!.payload.length, 32);
    expect(got!.chunkIndex, 0);
  });

  test('the stop closure ends polling', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    final stop = await reader.startReadSession(
      onChunkRead: (_, __) => reads++,
      onError: (_) {},
    );
    await pumpUntil(() => reads > 0);
    stop();
    expect(reader.isSessionActive, isFalse);

    final seen = reads;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reads, seen, reason: 'no further reads after stop');
  });

  test('the same card is not re-read while it rests on the reader', () async {
    // Without this, a card left in the field floods the restore loop with
    // duplicates of one chunk.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    var reads = 0;
    final stop = await _reader(dev)
        .startReadSession(onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stop();
    expect(reads, 1);
  });

  test('lifting and re-presenting a card reads it again', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    var reads = 0;
    final stop = await _reader(dev)
        .startReadSession(onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);
    dev.removeCard();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    dev.presentCard();
    await pumpUntil(() => reads == 2);
    stop();
    expect(reads, 2);
  });

  test('a foreign card reports an error but does NOT end the session',
      () async {
    // Auth failure means a hotel key on the reader, not a broken session.
    // Ending here would abort a restore because one wrong card was tapped.
    //
    // Sector 0 specifically: a genuine foreign card is keyed throughout, and
    // locking only a later sector would never surface — the first usable block
    // lives in sector 0, and a non-NFAR card is abandoned there as blank.
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {
        for (var s = 0; s < 16; s++)
          s: Uint8List.fromList(const [9, 9, 9, 9, 9, 9]),
      },
    );
    await dev.connect();

    final reader = _reader(dev);
    final errors = <NfcFailureKind>[];
    final stop = await reader.startReadSession(
      onChunkRead: (_, __) {},
      onError: (f) => errors.add(f.kind),
    );
    await pumpUntil(() => errors.isNotEmpty);
    expect(reader.isSessionActive, isTrue);
    expect(errors.first, NfcFailureKind.foreignCard);
    stop();
  });

  test(
      'a card without an NFAR chunk reports noArchiveData once and logs it at info',
      () async {
    // A blank card is a normal thing to tap during a restore, but the user
    // must be told why nothing happened. Once per tap: the resting-card guard
    // keeps a card left on the reader from repeating it every poll.
    log.clear();
    addTearDown(log.clear);
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();

    final errors = <NfcFailureKind>[];
    var reads = 0;
    final stop = await _reader(dev).startReadSession(
      onChunkRead: (_, __) => reads++,
      onError: (f) => errors.add(f.kind),
    );
    await pumpUntil(() => dev.scanCalls >= 3);
    stop();

    expect(reads, 0);
    expect(errors, [NfcFailureKind.noArchiveData]);
    final infos = log.snapshot().where((e) =>
        e.level == LogLevel.info && e.message == 'No NFAR chunk on card');
    expect(infos, hasLength(1));
  });

  group('writing', () {
    test('a chunk is written and verified by reading it back', () async {
      final dev = FakeChameleonDevice.classic1k();
      await dev.connect();

      NfcTagInfoLike? ok;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (info) => ok = info,
        onError: (_) {},
      );
      await pumpUntil(() => ok != null);
      stop();

      expect(await dev.readBlock(usableBlockIndexes.first, factoryKeyA),
          equals(chunkToBlocks(aChunk().toBytes()).first.data));
    });

    test('a write whose read-back differs is reported, not silently accepted',
        () async {
      final dev = FakeChameleonDevice.classic1k()..corruptWrites();
      await dev.connect();

      NfcFailure? err;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (f) => err = f,
      );
      await pumpUntil(() => err != null);
      stop();
      expect(err!.kind, NfcFailureKind.writeFailed);
    });

    test('a failed verification keeps card bytes out of the persisted log',
        () async {
      log.clear();
      addTearDown(log.clear);
      final dev = FakeChameleonDevice.classic1k()..corruptWrites();
      await dev.connect();

      NfcFailure? err;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (f) => err = f,
      );
      await pumpUntil(() => err != null);
      stop();

      final entry =
          log.snapshot().firstWhere((e) => e.message == 'Verification failed');
      expect(entry.level, LogLevel.error);
      final text = entry.formatFull();
      expect(text, contains('block'));
      expect(text, isNot(contains('wrote=')));
      expect(text, isNot(contains('read=')));
      final dbg = log
          .snapshot()
          .where((e) => e.message == 'Verification mismatch bytes');
      expect(dbg, hasLength(1));
      expect(dbg.single.level, LogLevel.debug);
    });

    test('too large with onTagTooSmall reports only too-small', () async {
      final dev = FakeChameleonDevice.classic1k();
      await dev.connect();

      var tooSmall = 0;
      final errors = <NfcFailureKind>[];
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(payloadLength: cardCapacityBytes + 100),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (f) => errors.add(f.kind),
        onTagTooSmall: (_, __, ___) => tooSmall++,
      );
      await pumpUntil(() => tooSmall > 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      stop();
      expect(tooSmall, 1);
      expect(errors, isEmpty);
    });

    test('a chunk too large for the card is rejected before any write',
        () async {
      final dev = FakeChameleonDevice.classic1k();
      await dev.connect();
      final before = await dev.readBlock(usableBlockIndexes.first, factoryKeyA);

      NfcFailure? err;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(payloadLength: cardCapacityBytes + 100),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (f) => err = f,
      );
      await pumpUntil(() => err != null);
      stop();
      expect(err!.kind, NfcFailureKind.writeFailed);

      expect(await dev.readBlock(usableBlockIndexes.first, factoryKeyA),
          equals(before),
          reason: 'nothing may be written when the chunk cannot fit');
    });
  });

  test('a resting card is not re-read when the session RESTARTS', () async {
    // Observed on hardware: the restore screen restarts the session after
    // every successful read (a phone-NFC habit, where one tap is one session).
    // Clearing the resting-card guard on start made the same card look new
    // each time, so it was re-read about once a second forever.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);

    // Restart exactly as the screen does after a success.
    final stop = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    stop();

    expect(reads, 1, reason: 'the card never left the field');
  });

  test('connecting clears the guard, so a card already resting is picked up',
      () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    final reader = _reader(dev);

    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);

    // Reconnecting is a fresh start: whatever is on the reader is new again.
    await reader.connect();
    final stop = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 2);
    stop();
    expect(reads, 2);
  });

  test('starting a session twice supersedes — it does not stack loops',
      () async {
    // The first hardware scan hung on exactly this: scan_screen restarts the
    // session on every error, each start spawned another poll loop, and they
    // all raced for a device that permits one command in flight. Only the
    // newest generation may keep polling.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    final stop2 = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads > 0);
    stop2();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(reader.isSessionActive, isFalse,
        reason: 'stopping the NEWEST session must stop all polling');
    final settled = reads;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reads, settled, reason: 'no orphaned loop is still running');
  });

  test('a stale stop closure cannot cancel the session that replaced it',
      () async {
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();
    final reader = _reader(dev);

    final stale =
        await reader.startReadSession(onChunkRead: (_, __) {}, onError: (_) {});
    await reader.startReadSession(onChunkRead: (_, __) {}, onError: (_) {});
    stale();

    expect(reader.isSessionActive, isTrue,
        reason: 'the newer session owns the loop');
  });

  test('rawDevice is the SAME instance every card operation uses', () async {
    // Constructing a second BleChameleonDevice for one physical reader gives
    // it its own pending-command slot and its own notification subscription,
    // so it writes commands nobody listens for while the first instance drops
    // the replies. Every inspection timed out on hardware because of exactly
    // that. The flag and the thing it gates must come from one object.
    final dev = FakeChameleonDevice.classic1k();
    final reader = ChameleonReader(dev, pollInterval: Duration.zero);
    expect(reader.supportsRawAccess, isTrue);
    expect(identical(reader.rawDevice, dev), isTrue);
  });

  test('connect and disconnect drive the underlying device', () async {
    final dev = FakeChameleonDevice.classic1k();
    final reader = ChameleonReader(dev, pollInterval: Duration.zero);
    await reader.connect();
    expect(dev.isConnected, isTrue);
    await reader.disconnect();
    expect(dev.disconnectCalls, 1);
  });

  group('Mifare Classic 4K', () {
    Future<Chunk?> readOnce(FakeChameleonDevice dev,
        {bool allow4k = false, List<NfcFailureKind>? errors}) async {
      await dev.connect();
      Chunk? got;
      final stop = await _reader(dev, allow4k: allow4k).startReadSession(
        onChunkRead: (c, _) => got = c,
        onError: (f) => errors?.add(f.kind),
      );
      await pumpUntil(() => got != null || (errors?.isNotEmpty ?? false));
      stop();
      return got;
    }

    Future<
            ({
              NfcTagInfo? ok,
              NfcFailure? err,
              List<int> tooSmall,
            })>
        writeOnce(FakeChameleonDevice dev, Chunk chunk,
            {required bool allow4k}) async {
      await dev.connect();
      NfcTagInfo? ok;
      NfcFailure? err;
      final tooSmall = <int>[];
      final stop = await _reader(dev, allow4k: allow4k).startWriteSession(
        chunk: chunk,
        configuredTagType: NfcTagType.mifareClassic4k,
        onSuccess: (i) => ok = i,
        onError: (f) => err = f,
        onTagTooSmall: (req, cap, _) => tooSmall.addAll([req, cap]),
      );
      await pumpUntil(() => ok != null || err != null || tooSmall.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      stop();
      return (ok: ok, err: err, tooSmall: tooSmall);
    }

    for (final sak in [0x18, 0x38, 0x98]) {
      test(
          '3,000 B chunk writes and reads back on SAK 0x${sak.toRadixString(16)}',
          () async {
        final dev = FakeChameleonDevice.classic4k(sak: sak);
        final chunk = aChunk(payloadLength: 3000 - NfarHeaderSize.total);
        final r = await writeOnce(dev, chunk, allow4k: true);
        expect(r.ok, isNotNull);
        expect(r.ok!.tagType, NfcTagType.mifareClassic4k);

        final got = await readOnce(dev, allow4k: true);
        expect(got!.toBytes(), equals(chunk.toBytes()));
      });
    }

    test('switch off: a 4K-sized chunk is reported too small, nothing written',
        () async {
      final dev = FakeChameleonDevice.classic4k();
      final r =
          await writeOnce(dev, aChunk(payloadLength: 3000), allow4k: false);
      expect(r.tooSmall, [3000 + NfarHeaderSize.total, cardCapacityBytes]);
      expect(r.ok, isNull);
      expect(r.err, isNull);
      expect(dev.writeLog, isEmpty);
    });

    test('switch off: a card written with it on still restores', () async {
      final dev = FakeChameleonDevice.classic4k();
      final chunk = aChunk(payloadLength: 3000);
      await writeOnce(dev, chunk, allow4k: true);
      final got = await readOnce(dev, allow4k: false);
      expect(got!.toBytes(), equals(chunk.toBytes()));
    });

    test('a non-factory key in a touched sector fails before any write',
        () async {
      final dev = FakeChameleonDevice.classic4k(
        sectorKeys: {
          33: Uint8List.fromList(const [1, 2, 3, 4, 5, 6])
        },
      );
      final r =
          await writeOnce(dev, aChunk(payloadLength: 3000), allow4k: true);
      expect(r.ok, isNull);
      expect(r.err, isNotNull);
      expect(dev.writeLog, isEmpty);
    });

    test('a chunk within 752 B on a 4K card does no pre-check reads', () async {
      final dev = FakeChameleonDevice.classic4k();
      final r = await writeOnce(dev, aChunk(payloadLength: 300), allow4k: true);
      expect(r.ok, isNotNull);
      expect(dev.writeLog, isNotEmpty);
      expect(dev.readLog, equals(dev.writeLog),
          reason: 'only the verify pass reads');
    });

    test('a chunk within 752 B on a 1K card: same blocks, no pre-check',
        () async {
      final dev = FakeChameleonDevice.classic1k();
      final chunk = aChunk(payloadLength: 300);
      final r = await writeOnce(dev, chunk, allow4k: true);
      expect(r.ok, isNotNull);
      expect(dev.writeLog,
          equals(chunkToBlocks(chunk.toBytes()).map((w) => w.block)));
      expect(dev.readLog, equals(dev.writeLog));
    });

    test('a 2K card (SAK 0x19) is unsupported on read and on write', () async {
      final errors = <NfcFailureKind>[];
      final got = await readOnce(FakeChameleonDevice.classic4k(sak: 0x19),
          allow4k: true, errors: errors);
      expect(got, isNull);
      expect(errors, [NfcFailureKind.readFailed]);

      final dev = FakeChameleonDevice.classic4k(sak: 0x19);
      final r = await writeOnce(dev, aChunk(), allow4k: true);
      expect(r.ok, isNull);
      expect(r.err, isNotNull);
      expect(dev.writeLog, isEmpty);
    });

    test('tag info: 4K type, capacity follows the switch', () async {
      for (final on in [true, false]) {
        final dev = FakeChameleonDevice.classic4k();
        await dev.connect();
        NfcTagInfo? info;
        final stop = await _reader(dev, allow4k: on).startReadSession(
          onChunkRead: (_, __) {},
          onError: (_) {},
          onTagDiscovered: (i) => info = i,
        );
        await pumpUntil(() => info != null);
        stop();
        expect(info!.tagType, NfcTagType.mifareClassic4k);
        expect(info!.capacity, on ? 3440 : 752);
      }
    });

    test('every tap logs the SAK at info level', () async {
      log.clear();
      addTearDown(log.clear);
      await readOnce(FakeChameleonDevice.classic4k(sak: 0x38),
          errors: <NfcFailureKind>[]);
      final e = log.snapshot().where(
          (e) => e.level == LogLevel.info && e.message == 'Tag discovered');
      expect(e.single.formatFull(), contains('0x38'));
    });
  });

  group('NTAG', () {
    Future<Chunk?> readOnce(
      FakeChameleonDevice dev, {
      List<NfcFailureKind> expectedErrors = const [],
    }) async {
      await dev.connect();
      Chunk? got;
      final errors = <NfcFailureKind>[];
      var discovered = false;
      final stop = await _reader(dev).startReadSession(
        onChunkRead: (c, _) => got = c,
        onError: (f) => errors.add(f.kind),
        onTagDiscovered: (_) => discovered = true,
      );
      await pumpUntil(() => discovered);
      // Discovery comes before the read; give the read time to finish.
      for (var i = 0; i < 200 && got == null && errors.isEmpty; i++) {
        await pump();
      }
      stop();
      expect(errors, expectedErrors);
      return got;
    }

    test('a small chunk is read', () async {
      final dev = FakeChameleonDevice.ntag215();
      dev.writeNfar(validChunkBytes(payloadLength: 32));
      final got = await readOnce(dev);
      expect(got!.payload.length, 32);
    });

    // A chunk sized for NTAG215 fills ~470 of its 504 user bytes. The read
    // used to stop after 64 pages (256 bytes) and report "no chunk", so no
    // full-size NTAG chunk could ever be restored through a Chameleon.
    test('a full-size NTAG215 chunk is read, not cut off at 256 bytes',
        () async {
      final dev = FakeChameleonDevice.ntag215();
      dev.writeNfar(validChunkBytes(payloadLength: 400));
      final got = await readOnce(dev);
      expect(got, isNotNull);
      expect(got!.payload.length, 400);
    });

    test('a factory-blank NTAG (empty NDEF TLV) reports noArchiveData',
        () async {
      final dev = FakeChameleonDevice.ntag215();
      await dev.transceive14a(
        Uint8List.fromList([0xA2, 4, 0x03, 0x00, 0xFE, 0x00]),
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: true,
      );
      expect(
        await readOnce(dev,
            expectedErrors: const [NfcFailureKind.noArchiveData]),
        isNull,
      );
    });
  });
}

/// Local alias so the test does not depend on the app's NfcTagInfo import path.
typedef NfcTagInfoLike = Object;
