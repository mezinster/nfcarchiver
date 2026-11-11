import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/models/nfc_tag_info.dart';
import '../domain/mifare_block_io.dart';
import '../domain/mifare_tag_codec.dart';
import '../domain/android_tech_list.dart';
import '../domain/card_reader.dart';
import '../domain/ndef_availability.dart';
import '../domain/ndef_formatter.dart';
import '../domain/ndef_io.dart';
import '../domain/ios_nfc_session.dart';
import '../domain/ndef_tag_codec.dart';
import '../domain/nfc_failure.dart';
import '../domain/polling_options.dart';
import '../domain/tag_codec.dart';
import 'nfc_capabilities.dart';
import '../../../core/log/logger.dart';
import '../domain/stale_tag_policy.dart';

/// Whether a tapped tag's medium disagrees with [configuredMedium].
///
/// Pure so it's testable without a real `NfcTag`/`NfcManager` session: the
/// write path's medium-mismatch check (Task 8) funnels its boolean decision
/// through here so the logic has a single, unit-testable source of truth.
@visibleForTesting
bool tagMediumMismatches({
  required bool tappedIsMifare,
  required TagMedium configuredMedium,
}) {
  final tappedMedium =
      tappedIsMifare ? TagMedium.mifareClassic : TagMedium.ndef;
  return tappedMedium != configuredMedium;
}

/// What iOS's system sheet says when a tag fails.
///
/// Fixed English, like every other sheet message: the sheet is a system
/// surface, and the raw exception that used to appear here belongs in the log.
@visibleForTesting
String iosSheetText(NfcFailure failure, {bool writing = false}) {
  switch (failure.kind) {
    case NfcFailureKind.noArchiveData:
      return 'No NFC Archiver data on this tag';
    case NfcFailureKind.tagNotWritable:
      return 'This tag is read-only.';
    default:
      return writing ? "Couldn't write this tag" : "Couldn't read this tag";
  }
}

/// Repository for NFC operations.
///
/// Provides a high-level API for reading and writing NFAR chunks to NFC tags.
class NfcRepository {
  /// Singleton instance
  static final NfcRepository instance = NfcRepository._();

  NfcRepository._();

  final _ndefFormatter = NdefFormatter.instance;

  final _ios = IosNfcSession(
    restartPolling: () => NfcManagerIos.instance.tagSessionRestartPolling(),
    invalidate: ({alertMessage, errorMessage}) => NfcManager.instance
        .stopSession(alertMessageIos: alertMessage, errorMessageIos: errorMessage),
  );

  /// Callbacks of the latest read arm. A session iOS ends late (its sheet may
  /// outlive the arm that opened it) reports to the current screen.
  ({
    void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    void Function(NfcFailure failure) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    void Function(ScanStop reason)? onStopped,
  })? _readHandlers;

  /// End iOS's sheet for the tag just read, showing [message] — as a failure
  /// if [problem]. The checkmark or cross, and its haptic, are the user's only
  /// feedback: the app's own vibration does not get through a sheet.
  void endTag(String message, {bool problem = false}) {
    unawaited(_ios.end(message: message, problem: problem));
  }

  bool _deviceSupportsMifare = false;

  final _staleTagPolicy = StaleTagPolicy();

  /// Drops whatever tag connection Android is still holding before a new
  /// session is armed — unless [StaleTagPolicy] says the carry-over is
  /// protecting us (see there for the two loops it prevents).
  ///
  /// While a card stays in the field NfcService keeps it "connected" through
  /// background presence checks, and answers a fresh `enableReaderMode` with
  /// `applyRouting: Not updating discovery parameters, tag connected` — the
  /// new session is armed but never told about the card, so the UI spins until
  /// the user happens to lift it. `disableReaderMode` is what makes the
  /// service disconnect ("Tag lost, restarting polling loop") and rediscover,
  /// so the card resting on the phone is delivered to the session about to
  /// start. Seen on a Pixel 8 Pro: a 0.8 s write sat unstarted for 4 minutes.
  ///
  /// Android-only: Core NFC has no such carry-over, and its `stopSession`
  /// would dismiss the system sheet.
  Future<void> _releaseStaleTagConnection(SessionKind kind) async {
    if (!_staleTagPolicy.shouldReleaseBefore(kind)) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await NfcManager.instance.stopSession();
      Logger.instance.debug('nfc', 'released stale tag connection');
    } catch (e) {
      Logger.instance.warn('nfc', 'release failed', {'error': e});
    }
  }

  /// Call once at startup, before any session.
  Future<void> initCapabilities() async {
    _deviceSupportsMifare = await hasMifareClassicSupport();
  }

  /// Mifare first: NDEF is never written onto Classic, so a tag exposing
  /// MifareClassic is unambiguously ours. NDEF handles everything else.
  final List<TagCodec> _codecs = [
    MifareTagCodec(mifareIoFor),
    NdefTagCodec(ndefIoFor),
  ];

  /// First codec that can handle this tag, or null.
  TagCodec? _codecFor(NfcTag tag) {
    for (final codec in _codecs) {
      if (codec.supports(tag)) return codec;
    }
    return null;
  }

  /// The codec list, in try order. Exposed read-only so a test can assert
  /// against the production ordering itself rather than a local copy of it.
  @visibleForTesting
  List<TagCodec> get codecs => List.unmodifiable(_codecs);

  /// Cooldown period after successful write to prevent immediate re-read
  static const _writeCooldown = Duration(milliseconds: 2000);

  /// Timestamp of last successful write
  DateTime? _lastWriteTime;

  /// Check if we're in write cooldown period
  bool get isInWriteCooldown {
    if (_lastWriteTime == null) return false;
    return DateTime.now().difference(_lastWriteTime!) < _writeCooldown;
  }

  /// Record a successful write
  void _recordWrite() {
    _lastWriteTime = DateTime.now();
  }

  /// Clear the write cooldown (call when starting a new unrelated operation)
  void clearWriteCooldown() {
    _lastWriteTime = null;
  }

  /// Check if NFC is available on this device.
  ///
  /// v4 deprecates the plugin's own `isAvailable()` in favour of
  /// [NfcManager.checkAvailability], which distinguishes "NFC is switched off"
  /// from "this device has no NFC at all". Collapsed back to a bool here to keep
  /// every caller's meaning identical; the richer state is available to any
  /// future caller that wants to tell the user which of the two it is.
  Future<bool> isAvailable() async {
    return await NfcManager.instance.checkAvailability() ==
        NfcAvailability.enabled;
  }

  /// Start an NFC session for reading chunks.
  ///
  /// [onChunkRead] is called when a chunk is successfully read.
  /// [onError] is called with a typed failure; the exception behind it, if
  /// any, is logged here first and never reaches the caller.
  /// [onTagDiscovered] is called when any tag is discovered (before reading).
  ///
  /// Returns a function to stop the session.
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(NfcFailure failure) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    void Function(ScanStop reason)? onStopped,
    String alertMessage = 'Hold your device near an NFC tag',
  }) async {
    if (!await isAvailable()) {
      throw const NfcNotAvailableException();
    }

    _readHandlers = (
      onChunkRead: onChunkRead,
      onError: onError,
      onTagDiscovered: onTagDiscovered,
      onStopped: onStopped,
    );
    final generation = ++_sessionGeneration;
    void stop() {
      // Also cancels a retry still waiting to begin (see _beginReadSession).
      _sessionGeneration++;
      _ios.stopped();
      NfcManager.instance.stopSession().catchError((Object _) {});
    }

    await _releaseStaleTagConnection(SessionKind.read);
    // Not awaited: on iOS the begin can wait seconds for the last sheet to
    // close, and the caller must hold `stop` meanwhile — leaving the screen in
    // that window has to cancel the sheet before it opens.
    unawaited(_beginReadSession(generation, alertMessage));
    return stop;
  }

  /// Bumped by every arm and every stop; a begin whose generation is stale was
  /// overtaken while it waited, and must not open a sheet.
  int _sessionGeneration = 0;

  Future<void> _beginReadSession(int generation, String alertMessage) async {
    await _ios.beforeBegin();
    if (generation != _sessionGeneration) return;
    Logger.instance.info('nfc.read', 'session armed');
    _ios.began();
    NfcManager.instance.startSession(
      pollingOptions: sessionPollingOptions(),
      alertMessageIos: alertMessage,
      onDiscovered: (tag) async {
        Logger.instance.info('nfc.read', 'tag discovered');
        // Ignore reads during write cooldown to prevent re-reading just-written tags
        if (isInWriteCooldown) {
          return;
        }

        final handlers = _readHandlers!;
        // A failure ends iOS's sheet before it is reported: reporting re-arms.
        // A good read is left open for the screen to end with endTag, since
        // only the screen knows whether the chunk is new or a duplicate.
        Future<void> fail(NfcFailure failure) async {
          await _ios.end(message: iosSheetText(failure), problem: true);
          handlers.onError(failure);
        }

        try {
          final tagInfo = _extractTagInfo(tag);
          if (_ios.isRepeat(tagInfo.identifier)) {
            // Still resting on the phone from the last read: not a new tap.
            Logger.instance.debug('nfc.read', 'resting tag ignored');
            await _ios.keepPolling();
            return;
          }
          handlers.onTagDiscovered?.call(tagInfo);

          final codec = _codecFor(tag);
          if (codec == null) {
            final reason = _ndefUnavailableReason(tag);
            Logger.instance.info('nfc.read', 'No usable technology on tag',
                {'uid': tagInfo.identifier, 'reason': reason.name});
            await fail(failureFor(reason));
            return;
          }
          final chunk = await codec.readChunk(tag);
          // The card was read to the end, whatever it held: we are done with
          // it, so the re-arm that follows must not rediscover it. A read
          // that THROWS (tag lost, I/O) skips this and is retried in place.
          _staleTagPolicy.succeeded(SessionKind.read);

          if (chunk == null) {
            Logger.instance.info(
                'nfc.read', 'No NFAR chunk on tag', {'uid': tagInfo.identifier});
            await fail(const NfcFailure(NfcFailureKind.noArchiveData));
            return;
          }
          Logger.instance.info('nfc.read', 'chunk read', {'index': chunk.chunkIndex});
          handlers.onChunkRead(chunk, tagInfo);
        } catch (e, st) {
          Logger.instance.report('nfc.read', 'Tag read failed', e, st);
          await fail(const NfcFailure(NfcFailureKind.readFailed));
        }
      },
      onSessionErrorIos: (error) async {
        Logger.instance.warn('nfc.read', 'ios session error', {'code': error.code.name, 'message': error.message});
        if (_ios.refusedAtBegin(error.code)) {
          // Not ready yet — the last sheet is still closing. Try again
          // shortly, without telling the screen: there is nothing to report.
          Logger.instance.debug('nfc.read', 'begin refused, retrying');
          await _ios.retryAfterRefusal();
          unawaited(_beginReadSession(generation, alertMessage));
          return;
        }
        await _ios.invalidatedBySystem();
        final handlers = _readHandlers;
        final stop = scanStopFor(error.code);
        // Re-arming after Cancel or a timeout re-opens the sheet the user
        // just dismissed; with no onStopped, fall back to the error path.
        if (stop != null && handlers?.onStopped != null) {
          handlers!.onStopped!(stop);
        } else {
          // The ios session error line above holds the code and message.
          handlers?.onError(const NfcFailure(NfcFailureKind.unknown));
        }
      },
    ).catchError((Object e) {
      // Unawaited, so a refused start (e.g. session_already_exists) would
      // otherwise vanish into the zone and leave the UI waiting forever.
      Logger.instance.warn('nfc.read', 'startSession failed', {'error': e});
      _ios.stopped();
    });
  }

  /// Start an NFC session for writing a chunk.
  ///
  /// [chunk] is the chunk to write.
  /// [configuredTagType] is the tag type the archive was configured for; a
  /// tapped tag whose medium (NDEF vs Mifare Classic) doesn't match it is
  /// rejected via [onTagTypeMismatch] before any write is attempted.
  /// [onSuccess] is called when the chunk is successfully written.
  /// [onError] is called with a typed failure; the exception behind it, if
  /// any, is logged here first and never reaches the caller.
  /// [onTagTooSmall] is called when the tag doesn't have enough capacity.
  /// [onTagTypeMismatch] is called when the tapped tag's medium doesn't match
  /// [configuredTagType].
  ///
  /// Returns a function to stop the session.
  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(NfcFailure failure) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)?
        onTagTooSmall,
    void Function(String tappedMedium, String configuredMedium,
            NfcTagInfo? tagInfo)?
        onTagTypeMismatch,
    void Function(ScanStop reason)? onStopped,
    String alertMessage = 'Hold your device near an NFC tag to write',
  }) async {
    if (!await isAvailable()) {
      throw const NfcNotAvailableException();
    }

    final log = Logger.instance;
    final generation = ++_sessionGeneration;
    void stop() {
      // Also cancels a begin still waiting for the last sheet to close.
      _sessionGeneration++;
      _ios.stopped();
      NfcManager.instance.stopSession().catchError((Object _) {});
    }

    // A failure ends iOS's sheet as an error before it is reported: the
    // screen's retry must not find it still open (see IosNfcSession).
    Future<void> fail(String sheetMessage, void Function() report) async {
      await _ios.end(message: sheetMessage, problem: true);
      report();
    }

    Future<void> begin() async {
      await _ios.beforeBegin();
      if (generation != _sessionGeneration) return;
      log.info('nfc.write', 'session armed', {
        'chunk': chunk.chunkIndex,
        'bytes': chunk.totalSize,
        'configured': configuredTagType.name,
      });
      _ios.began();
      NfcManager.instance.startSession(
        pollingOptions: sessionPollingOptions(),
        alertMessageIos: alertMessage,
        onDiscovered: (tag) async {
          try {
            log.info('nfc.write', 'tag discovered');
            final tagInfo = _extractTagInfo(tag);
            final codec = _codecFor(tag);
            log.info('nfc.write', 'codec selected', {'codec': codec?.name});

            if (codec == null) {
              final failure = failureFor(_ndefUnavailableReason(tag));
              log.info('nfc.write', 'No usable technology on tag',
                  {'uid': tagInfo.identifier, 'reason': failure.kind.name});
              await fail(iosSheetText(failure, writing: true),
                  () => onError(failure));
              return;
            }

            // The tapped tag's medium must match what the archive was
            // configured for. `codec is MifareTagCodec` is the ground truth for
            // which medium was actually selected (routing is Mifare-first, see
            // `_codecFor`), so this can't be fooled by e.g. a Mifare Classic
            // card that some other app happened to NDEF-format. Checked before
            // any medium-specific pre-check or write, so a mismatch never
            // reaches `codec.writeChunk`.
            if (tagMediumMismatches(
              tappedIsMifare: codec is MifareTagCodec,
              configuredMedium: configuredTagType.medium,
            )) {
              final message =
                  "That's a ${codec.name} card, but this archive is configured "
                  'for ${configuredTagType.name} — change the tag type in '
                  'Settings.';
              await fail(message, () {
                if (onTagTypeMismatch != null) {
                  onTagTypeMismatch(codec.name, configuredTagType.name, tagInfo);
                } else {
                  onError(const NfcFailure(NfcFailureKind.writeFailed));
                }
              });
              return;
            }

            // These pre-write checks are NDEF-specific and must key off which
            // codec was actually selected, not off `Ndef.from(tag) != null`: a
            // Mifare Classic card that some other app happened to NDEF-format
            // still has non-null NDEF data, but Mifare-first routing still
            // selects MifareTagCodec for it, and NDEF's writability/size numbers
            // do not describe that raw block write. `codec is NdefTagCodec` is
            // strictly narrower than `ndef != null` (it also requires
            // MifareTagCodec.supports(tag) to have been false), so this cannot
            // change behaviour for a tag that actually gets the NDEF codec.
            // NDEF's checks and messages are unchanged: this is the same
            // `ndef.maxSize` vs `requiredNdefSize(chunk)` comparison as before,
            // not the (1-4 byte stricter) `codec.capacityBytes(tag)` used below
            // for other media.
            if (codec is NdefTagCodec) {
              final ndef = ndefIoFor(tag)!;
              if (!ndef.isWritable) {
                const failure = NfcFailure(NfcFailureKind.tagNotWritable);
                log.info('nfc.write', 'Tag is read-only', {'uid': tagInfo.identifier});
                await fail(iosSheetText(failure, writing: true),
                    () => onError(failure));
                return;
              }

              final requiredSize = _ndefFormatter.requiredNdefSize(chunk);
              if (ndef.maxSize < requiredSize) {
                final message = 'Tag too small: needs $requiredSize bytes, '
                    'has ${ndef.maxSize} bytes';
                await fail(message, () {
                  if (onTagTooSmall != null) {
                    onTagTooSmall(requiredSize, ndef.maxSize, tagInfo);
                  } else {
                    onError(const NfcFailure(NfcFailureKind.writeFailed));
                  }
                });
                return;
              }
            } else {
              // Non-NDEF media (Mifare Classic): `capacityBytes` is defined as
              // chunk bytes, so it's directly comparable to `chunk.totalSize`.
              // Checked before `writeChunk` so an oversized chunk is reported
              // via `onTagTooSmall` (the same re-chunk offer NDEF gets) instead
              // of failing mid-write with a raw `MifareCapacityException`.
              //
              // Reachable: a card smaller than the configured type (e.g. a
              // 4K archive meeting a 1K card, or a 4K card with the 4K switch
              // off). The consumer re-chunks with the medium-aware payload.
              final capacity = await codec.capacityBytes(tag);
              if (chunk.totalSize > capacity) {
                final message = 'Tag too small: needs ${chunk.totalSize} bytes, '
                    'has $capacity bytes';
                await fail(message, () {
                  if (onTagTooSmall != null) {
                    onTagTooSmall(chunk.totalSize, capacity, tagInfo);
                  } else {
                    onError(const NfcFailure(NfcFailureKind.writeFailed));
                  }
                });
                return;
              }
            }

            log.info('nfc.write', 'writeChunk start');
            await codec.writeChunk(tag, chunk);
            log.info('nfc.write', 'writeChunk done');
            _recordWrite(); // Start cooldown to prevent immediate re-read
            _staleTagPolicy.succeeded(SessionKind.write);
            // Left open: the screen ends iOS's sheet with its own "written"
            // message (endTag), the way the restore screen does for reads.
            onSuccess(tagInfo);
          } on TagNotWritableException catch (e, st) {
            log.report('nfc.write', 'Tag is read-only', e, st);
            const failure = NfcFailure(NfcFailureKind.tagNotWritable);
            await fail(iosSheetText(failure, writing: true),
                () => onError(failure));
          } catch (e, st) {
            log.report('nfc.write', 'Tag write failed', e, st);
            const failure = NfcFailure(NfcFailureKind.writeFailed);
            await fail(iosSheetText(failure, writing: true),
                () => onError(failure));
          }
        },
        onSessionErrorIos: (error) async {
          log.warn('nfc.write', 'ios session error',
              {'code': error.code.name, 'message': error.message});
          if (_ios.refusedAtBegin(error.code)) {
            // Not ready yet — the last sheet is still closing. Try again
            // shortly, without telling the screen (see IosNfcSession).
            log.debug('nfc.write', 'begin refused, retrying');
            await _ios.retryAfterRefusal();
            unawaited(begin());
            return;
          }
          await _ios.invalidatedBySystem();
          final stopReason = scanStopFor(error.code);
          // Cancelling the sheet is the user's choice, not a write error.
          if (stopReason != null && onStopped != null) {
            onStopped(stopReason);
          } else {
            // The ios session error line above holds the code and message.
            onError(const NfcFailure(NfcFailureKind.unknown));
          }
        },
      ).catchError((Object e) {
        // Unawaited, so a refused start would otherwise vanish into the zone
        // and leave the UI waiting forever.
        log.warn('nfc.write', 'startSession failed', {'error': e});
        _ios.stopped();
      });
    }

    await _releaseStaleTagConnection(SessionKind.write);
    // Not awaited: on iOS the begin can wait seconds for the last sheet to
    // close, and the caller must hold `stop` meanwhile.
    unawaited(begin());
    return stop;
  }

  /// Read a single tag and return the chunk.
  ///
  /// This is a convenience method that wraps the session API.
  Future<NfcReadResult> readTag({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await isAvailable()) {
      return const NfcReadError(
          failure: NfcFailure(NfcFailureKind.nfcUnavailable));
    }

    final completer = Completer<NfcReadResult>();
    Timer? timeoutTimer;

    void Function()? stopSession;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        stopSession?.call();
        Logger.instance.info('nfc.read', 'Timeout waiting for NFC tag');
        completer.complete(
          const NfcReadError(failure: NfcFailure(NfcFailureKind.readFailed)),
        );
      }
    });

    try {
      stopSession = await startReadSession(
        onChunkRead: (chunk, tagInfo) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcReadSuccess(
              tagInfo: tagInfo,
              data: chunk.toBytes(),
            ));
          }
        },
        onError: (failure) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcReadError(failure: failure));
          }
        },
      );
    } catch (e, st) {
      timeoutTimer.cancel();
      Logger.instance.report('nfc.read', 'Read session failed to start', e, st);
      return const NfcReadError(failure: NfcFailure(NfcFailureKind.unknown));
    }

    return completer.future;
  }

  /// Write a chunk to a single tag.
  ///
  /// This is a convenience method that wraps the session API.
  Future<NfcWriteResult> writeTag({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await isAvailable()) {
      return const NfcWriteError(
          failure: NfcFailure(NfcFailureKind.nfcUnavailable));
    }

    final completer = Completer<NfcWriteResult>();
    Timer? timeoutTimer;

    void Function()? stopSession;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        stopSession?.call();
        Logger.instance.info('nfc.write', 'Timeout waiting for NFC tag');
        completer.complete(
          const NfcWriteError(failure: NfcFailure(NfcFailureKind.writeFailed)),
        );
      }
    });

    try {
      stopSession = await startWriteSession(
        chunk: chunk,
        configuredTagType: configuredTagType,
        onSuccess: (tagInfo) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcWriteSuccess(
              tagInfo: tagInfo,
              bytesWritten: chunk.totalSize,
            ));
          }
        },
        onError: (failure) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcWriteError(failure: failure));
          }
        },
      );
    } catch (e, st) {
      timeoutTimer.cancel();
      Logger.instance.report('nfc.write', 'Write session failed to start', e, st);
      return const NfcWriteError(failure: NfcFailure(NfcFailureKind.unknown));
    }

    return completer.future;
  }

  /// Stop any active NFC session.
  void stopSession({String? message}) {
    _ios.stopped();
    NfcManager.instance
        .stopSession(alertMessageIos: message, errorMessageIos: null)
        // No session open (e.g. iOS already ended it): nothing to stop.
        .catchError((Object _) {});
  }

  /// Why this tag came back without the `Ndef` technology.
  ///
  /// The techs the platform *did* attach are the evidence: an `NfcA` or
  /// `MifareUltralight` tag whose NDEF detection failed is a good tag that was
  /// tapped badly, not one the user needs to replace.
  NdefUnavailableReason _ndefUnavailableReason(NfcTag tag) {
    // v3 read these off an untyped map; v4 exposes a typed tech list. Same
    // evidence, looked up by class name instead of map key.
    final techList = NfcTagAndroid.from(tag)?.techList ?? const <String>[];
    return classifyNdefUnavailable(
      hasNfcA: androidHasTech(techList, 'NfcA'),
      hasMifareUltralight: androidHasTech(techList, 'MifareUltralight'),
      deviceSupportsMifare: _deviceSupportsMifare,
    );
  }

  /// Colon-separated lowercase hex, matching the identifier format v3 produced
  /// from the untyped map ('04:1a:2b:...').
  String _hexId(List<int> id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  /// Extract tag info from NFC tag.
  NfcTagInfo _extractTagInfo(NfcTag tag) {
    String identifier = '';
    int capacity = 0;
    bool isWritable = true;
    NfcTagType? tagType;
    final technologies = <String>[];

    // Try to get NDEF info
    final codec = _codecFor(tag);
    final ndef = codec != null ? ndefIoFor(tag) : null;
    if (ndef != null) {
      capacity = ndef.maxSize;
      isWritable = ndef.isWritable;
      technologies.add('NDEF');
    }

    // Android exposes the tag's identity and technology list up front; v3
    // required probing an untyped map key per technology.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final atag = NfcTagAndroid.from(tag);
      if (atag != null) {
        if (atag.id.isNotEmpty) identifier = _hexId(atag.id);
        technologies.addAll(androidTechLabels(atag.techList));

        final ultralight = MifareUltralightAndroid.from(tag);
        switch (ultralight?.type) {
          case MifareUltralightTypeAndroid.ultralight:
            tagType = NfcTagType.mifareUltralight;
          case MifareUltralightTypeAndroid.ultralightC:
            tagType = NfcTagType.mifareUltralightC;
          case MifareUltralightTypeAndroid.unknown:
          case null:
            break;
        }
      }
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // NTAG and Mifare arrive as MiFare; without this an NTAG has no ID on
      // iOS, and a tag resting on the phone can't be told from a new one.
      final mifare = MiFareIos.from(tag);
      if (mifare != null && mifare.identifier.isNotEmpty) {
        identifier = _hexId(mifare.identifier);
      }
      final iso15693 = Iso15693Ios.from(tag);
      if (iso15693 != null) {
        identifier = _hexId(iso15693.identifier);
        technologies.add('ISO15693');
      }
      if (FeliCaIos.from(tag) != null) technologies.add('FeliCa');
    }

    // Infer tag type from capacity if not already set
    if (tagType == null && capacity > 0) {
      for (final type in NfcTagType.values) {
        if (type.capacity == capacity) {
          tagType = type;
          break;
        }
      }
    }

    return NfcTagInfo(
      identifier: identifier.isNotEmpty ? identifier : 'unknown',
      capacity: capacity,
      isWritable: isWritable,
      isNdefCapable: ndef != null,
      tagType: tagType,
      technologies: technologies,
    );
  }
}

/// Exception thrown when NFC is not available.
class NfcNotAvailableException implements Exception {
  const NfcNotAvailableException();

  @override
  String toString() => 'NFC is not available on this device';
}
