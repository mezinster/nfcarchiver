import 'dart:async';

import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/models/nfc_tag_info.dart';
import '../domain/ndef_formatter.dart';

/// Repository for NFC operations.
///
/// Provides a high-level API for reading and writing NFAR chunks to NFC tags.
class NfcRepository {
  /// Singleton instance
  static final NfcRepository instance = NfcRepository._();

  NfcRepository._();

  final _ndefFormatter = NdefFormatter.instance;

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
  Future<bool> isAvailable() async {
    return NfcManager.instance.isAvailable();
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
      alertMessage: alertMessage,
      onDiscovered: (tag) async {
        // Ignore reads during write cooldown to prevent re-reading just-written tags
        if (isInWriteCooldown) {
          return;
        }

        try {
          final tagInfo = _extractTagInfo(tag);
          onTagDiscovered?.call(tagInfo);

          final ndef = Ndef.from(tag);
          if (ndef == null) {
            onError('Tag does not support NDEF');
            return;
          }

          final message = await ndef.read();
          final chunk = _ndefFormatter.ndefToChunk(message);

          if (chunk == null) {
            onError('Tag does not contain valid archive data');
            return;
          }

          onChunkRead(chunk, tagInfo);
        } catch (e) {
          onError('Failed to read tag: $e');
        }
      },
      onError: (error) async {
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
  /// [onSuccess] is called when the chunk is successfully written.
  /// [onError] is called when an error occurs.
  /// [onTagTooSmall] is called when the tag doesn't have enough capacity.
  ///
  /// Returns a function to stop the session.
  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(String message) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)?
        onTagTooSmall,
    String alertMessage = 'Hold your device near an NFC tag to write',
  }) async {
    if (!await isAvailable()) {
      throw NfcNotAvailableException();
    }

    final completer = Completer<void Function()>();
    final message = _ndefFormatter.chunkToNdef(chunk);

    NfcManager.instance.startSession(
      alertMessage: alertMessage,
      onDiscovered: (tag) async {
        try {
          final tagInfo = _extractTagInfo(tag);
          final ndef = Ndef.from(tag);

          if (ndef == null) {
            onError('Tag does not support NDEF. Please use a pre-formatted NDEF tag.');
            return;
          }

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

          await ndef.write(message);
          _recordWrite(); // Start cooldown to prevent immediate re-read
          onSuccess(tagInfo);
        } catch (e) {
          onError('Failed to write tag: $e');
        }
      },
      onError: (error) async {
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
      alertMessage: message,
      errorMessage: null,
    );
  }

  /// Extract tag info from NFC tag.
  NfcTagInfo _extractTagInfo(NfcTag tag) {
    String identifier = '';
    int capacity = 0;
    bool isWritable = true;
    NfcTagType? tagType;
    final technologies = <String>[];

    // Try to get NDEF info
    final ndef = Ndef.from(tag);
    if (ndef != null) {
      capacity = ndef.maxSize;
      isWritable = ndef.isWritable;
      technologies.add('NDEF');
    }

    // Try NfcA (Android)
    final nfcAData = tag.data['nfca'];
    final nfcA = nfcAData is Map ? Map<String, dynamic>.from(nfcAData) : null;
    if (nfcA != null) {
      final id = nfcA['identifier'] as List<dynamic>?;
      if (id != null) {
        identifier = id.map((b) => (b as int).toRadixString(16).padLeft(2, '0')).join(':');
      }
      technologies.add('NfcA');
    }

    // Try MifareUltralight (Android)
    final mifareData = tag.data['mifareultralight'];
    final mifare = mifareData is Map ? Map<String, dynamic>.from(mifareData) : null;
    if (mifare != null) {
      final type = mifare['type'] as int?;
      if (type == 1) {
        tagType = NfcTagType.mifareUltralight;
      } else if (type == 2) {
        tagType = NfcTagType.mifareUltralightC;
      }
      technologies.add('MifareUltralight');
    }

    // Try ISO15693 (iOS)
    final iso15693Data = tag.data['iso15693'];
    final iso15693 = iso15693Data is Map ? Map<String, dynamic>.from(iso15693Data) : null;
    if (iso15693 != null) {
      final id = iso15693['identifier'] as List<dynamic>?;
      if (id != null) {
        identifier = id.map((b) => (b as int).toRadixString(16).padLeft(2, '0')).join(':');
      }
      technologies.add('ISO15693');
    }

    // Try FeliCa (iOS/Android)
    final felicaData = tag.data['felica'];
    final felica = felicaData is Map ? Map<String, dynamic>.from(felicaData) : null;
    if (felica != null) {
      technologies.add('FeliCa');
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
