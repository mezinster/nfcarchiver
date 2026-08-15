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
import '../domain/ndef_availability.dart';
import '../domain/ndef_formatter.dart';
import '../domain/ndef_io.dart';
import '../domain/ndef_tag_codec.dart';
import '../domain/tag_codec.dart';
import 'nfc_capabilities.dart';

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

/// Repository for NFC operations.
///
/// Provides a high-level API for reading and writing NFAR chunks to NFC tags.
class NfcRepository {
  /// Singleton instance
  static final NfcRepository instance = NfcRepository._();

  NfcRepository._();

  final _ndefFormatter = NdefFormatter.instance;

  bool _deviceSupportsMifare = false;

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
  /// [onError] is called when an error occurs.
  /// [onTagDiscovered] is called when any tag is discovered (before reading).
  ///
  /// Returns a function to stop the session.
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    String alertMessage = 'Hold your device near an NFC tag',
  }) async {
    if (!await isAvailable()) {
      throw NfcNotAvailableException();
    }

    final completer = Completer<void Function()>();

    NfcManager.instance.startSession(
      // Required in v4. v3 defaulted to `NfcPollingOption.values.toSet()`, so
      // passing anything narrower here would silently stop discovering tags.
      pollingOptions: NfcPollingOption.values.toSet(),
      alertMessageIos: alertMessage,
      onDiscovered: (tag) async {
        // Ignore reads during write cooldown to prevent re-reading just-written tags
        if (isInWriteCooldown) {
          return;
        }

        try {
          final tagInfo = _extractTagInfo(tag);
          onTagDiscovered?.call(tagInfo);

          final codec = _codecFor(tag);
          if (codec == null) {
            onError(messageFor(_ndefUnavailableReason(tag)));
            return;
          }

          final chunk = await codec.readChunk(tag);

          if (chunk == null) {
            onError('Tag does not contain valid archive data');
            return;
          }

          onChunkRead(chunk, tagInfo);
        } catch (e) {
          onError('Failed to read tag: $e');
        }
      },
      onSessionErrorIos: (error) {
        onError(error.message);
      },
    );

    completer.complete(() {
      NfcManager.instance.stopSession();
    });

    return completer.future;
  }

  /// Start an NFC session for writing a chunk.
  ///
  /// [chunk] is the chunk to write.
  /// [configuredTagType] is the tag type the archive was configured for; a
  /// tapped tag whose medium (NDEF vs Mifare Classic) doesn't match it is
  /// rejected via [onTagTypeMismatch] before any write is attempted.
  /// [onSuccess] is called when the chunk is successfully written.
  /// [onError] is called when an error occurs.
  /// [onTagTooSmall] is called when the tag doesn't have enough capacity.
  /// [onTagTypeMismatch] is called when the tapped tag's medium doesn't match
  /// [configuredTagType].
  ///
  /// Returns a function to stop the session.
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
    String alertMessage = 'Hold your device near an NFC tag to write',
  }) async {
    if (!await isAvailable()) {
      throw NfcNotAvailableException();
    }

    final completer = Completer<void Function()>();

    NfcManager.instance.startSession(
      // Required in v4. v3 defaulted to `NfcPollingOption.values.toSet()`, so
      // passing anything narrower here would silently stop discovering tags.
      pollingOptions: NfcPollingOption.values.toSet(),
      alertMessageIos: alertMessage,
      onDiscovered: (tag) async {
        try {
          final tagInfo = _extractTagInfo(tag);
          final codec = _codecFor(tag);

          if (codec == null) {
            onError(messageFor(_ndefUnavailableReason(tag)));
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
            if (onTagTypeMismatch != null) {
              onTagTypeMismatch(codec.name, configuredTagType.name, tagInfo);
            } else {
              onError(
                "That's a ${codec.name} card, but this archive is configured "
                'for ${configuredTagType.name} — change the tag type in '
                'Settings.',
              );
            }
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
              onError('Tag is not writable');
              return;
            }

            final requiredSize = _ndefFormatter.requiredNdefSize(chunk);
            if (ndef.maxSize < requiredSize) {
              if (onTagTooSmall != null) {
                onTagTooSmall(requiredSize, ndef.maxSize, tagInfo);
              } else {
                onError(
                  'Tag too small: needs $requiredSize bytes, '
                  'has ${ndef.maxSize} bytes',
                );
              }
              return;
            }
          } else {
            // Non-NDEF media (Mifare Classic): `capacityBytes` is defined as
            // chunk bytes, so it's directly comparable to `chunk.totalSize`.
            // Checked before `writeChunk` so an oversized chunk is reported
            // via `onTagTooSmall` (the same re-chunk offer NDEF gets) instead
            // of failing mid-write with a raw `MifareCapacityException`.
            //
            // This branch is currently unreachable: `mifareClassic1k` is the
            // only `TagMedium.mifareClassic` type, its capacity (752) equals
            // `MifareTagCodec.capacityBytes`, and the tag-type picker refuses
            // to render once an archive is prepared, so the configured medium
            // can't change mid-archive. Kept as defence-in-depth for the day
            // a second Mifare medium exists.
            //
            // If that day comes: `onTagTooSmall`'s consumer,
            // `_showRechunkDialog`, computes the rechunk size via
            // `NfcTagType.maxPayloadForCapacity(detectedCapacity)`, which is
            // NDEF-shaped (subtracts NDEF record/terminator overhead). For
            // capacity 752 that yields 680 — the wrong payload for Mifare,
            // whose real payload is 720. That formula must be fixed before
            // this branch can fire for a real Mifare "too small" case.
            final capacity = await codec.capacityBytes(tag);
            if (chunk.totalSize > capacity) {
              if (onTagTooSmall != null) {
                onTagTooSmall(chunk.totalSize, capacity, tagInfo);
              } else {
                onError(
                  'Tag too small: needs ${chunk.totalSize} bytes, '
                  'has $capacity bytes',
                );
              }
              return;
            }
          }

          await codec.writeChunk(tag, chunk);
          _recordWrite(); // Start cooldown to prevent immediate re-read
          onSuccess(tagInfo);
        } catch (e) {
          onError('Failed to write tag: $e');
        }
      },
      onSessionErrorIos: (error) {
        onError(error.message);
      },
    );

    completer.complete(() {
      NfcManager.instance.stopSession();
    });

    return completer.future;
  }

  /// Read a single tag and return the chunk.
  ///
  /// This is a convenience method that wraps the session API.
  Future<NfcReadResult> readTag({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await isAvailable()) {
      return const NfcReadError(message: 'NFC is not available');
    }

    final completer = Completer<NfcReadResult>();
    Timer? timeoutTimer;

    void Function()? stopSession;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        stopSession?.call();
        completer.complete(
          const NfcReadError(message: 'Timeout waiting for NFC tag'),
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
        onError: (message) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcReadError(message: message));
          }
        },
      );
    } catch (e) {
      timeoutTimer.cancel();
      return NfcReadError(message: e.toString());
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
      return const NfcWriteError(message: 'NFC is not available');
    }

    final completer = Completer<NfcWriteResult>();
    Timer? timeoutTimer;

    void Function()? stopSession;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        stopSession?.call();
        completer.complete(
          const NfcWriteError(message: 'Timeout waiting for NFC tag'),
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
        onError: (message) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            stopSession?.call();
            completer.complete(NfcWriteError(message: message));
          }
        },
      );
    } catch (e) {
      timeoutTimer.cancel();
      return NfcWriteError(message: e.toString());
    }

    return completer.future;
  }

  /// Stop any active NFC session.
  void stopSession({String? message}) {
    NfcManager.instance.stopSession(
      alertMessageIos: message,
      errorMessageIos: null,
    );
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
