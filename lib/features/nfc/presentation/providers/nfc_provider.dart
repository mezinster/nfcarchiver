import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chunk.dart';
import '../../../../core/models/nfc_tag_info.dart';
import '../../data/nfc_repository.dart';

/// Provider for NFC availability.
final nfcAvailableProvider = FutureProvider<bool>((ref) async {
  return NfcRepository.instance.isAvailable();
});

/// State for NFC session.
sealed class NfcSessionState {
  const NfcSessionState();
}

/// NFC session is idle (not active).
class NfcSessionIdle extends NfcSessionState {
  const NfcSessionIdle();
}

/// NFC session is waiting for a tag.
class NfcSessionWaiting extends NfcSessionState {
  const NfcSessionWaiting({
    required this.mode,
    this.message,
  });

  final NfcSessionMode mode;
  final String? message;
}

/// NFC session read a chunk successfully.
class NfcSessionReadSuccess extends NfcSessionState {
  const NfcSessionReadSuccess({
    required this.chunk,
    required this.tagInfo,
  });

  final Chunk chunk;
  final NfcTagInfo tagInfo;
}

/// NFC session wrote successfully - waiting for tag removal.
class NfcSessionWriteSuccess extends NfcSessionState {
  const NfcSessionWriteSuccess({
    required this.tagInfo,
    required this.bytesWritten,
    this.waitingForRemoval = true,
  });

  final NfcTagInfo tagInfo;
  final int bytesWritten;
  /// If true, user should remove tag before continuing
  final bool waitingForRemoval;
}

/// NFC session encountered an error.
class NfcSessionError extends NfcSessionState {
  const NfcSessionError({
    required this.message,
    this.tagInfo,
  });

  final String message;
  final NfcTagInfo? tagInfo;
}

/// NFC tag is too small for the chunk.
/// This is a special error that allows the app to offer rechunking.
class NfcSessionTagTooSmall extends NfcSessionState {
  const NfcSessionTagTooSmall({
    required this.requiredSize,
    required this.detectedCapacity,
    this.tagInfo,
  });

  final int requiredSize;
  final int detectedCapacity;
  final NfcTagInfo? tagInfo;

  String get message =>
      'Tag too small: needs $requiredSize bytes, has $detectedCapacity bytes';
}

/// Mode of NFC session.
enum NfcSessionMode {
  read,
  write,
}

/// Notifier for managing NFC session state.
class NfcSessionNotifier extends StateNotifier<NfcSessionState> {
  NfcSessionNotifier() : super(const NfcSessionIdle());

  final _repository = NfcRepository.instance;
  void Function()? _stopSession;

  /// Start a read session.
  Future<void> startReadSession({String? message}) async {
    if (!await _repository.isAvailable()) {
      state = const NfcSessionError(message: 'NFC is not available');
      return;
    }

    state = NfcSessionWaiting(
      mode: NfcSessionMode.read,
      message: message ?? 'Hold your device near an NFC tag',
    );

    try {
      _stopSession = await _repository.startReadSession(
        alertMessage: message ?? 'Hold your device near an NFC tag',
        onChunkRead: (chunk, tagInfo) {
          state = NfcSessionReadSuccess(chunk: chunk, tagInfo: tagInfo);
        },
        onError: (errorMessage) {
          state = NfcSessionError(message: errorMessage);
        },
        onTagDiscovered: (tagInfo) {
          // Could update state to show tag detected
        },
      );
    } catch (e) {
      state = NfcSessionError(message: e.toString());
    }
  }

  /// Start a write session.
  Future<void> startWriteSession({
    required Chunk chunk,
    String? message,
  }) async {
    if (!await _repository.isAvailable()) {
      state = const NfcSessionError(message: 'NFC is not available');
      return;
    }

    state = NfcSessionWaiting(
      mode: NfcSessionMode.write,
      message: message ?? 'Hold your device near an NFC tag to write',
    );

    try {
      _stopSession = await _repository.startWriteSession(
        chunk: chunk,
        alertMessage: message ?? 'Hold your device near an NFC tag to write',
        onSuccess: (tagInfo) {
          state = NfcSessionWriteSuccess(
            tagInfo: tagInfo,
            bytesWritten: chunk.totalSize,
          );
        },
        onError: (errorMessage) {
          state = NfcSessionError(message: errorMessage);
        },
        onTagTooSmall: (requiredSize, detectedCapacity, tagInfo) {
          state = NfcSessionTagTooSmall(
            requiredSize: requiredSize,
            detectedCapacity: detectedCapacity,
            tagInfo: tagInfo,
          );
        },
      );
    } catch (e) {
      state = NfcSessionError(message: e.toString());
    }
  }

  /// Stop the current session.
  void stopSession() {
    _stopSession?.call();
    _stopSession = null;
    state = const NfcSessionIdle();
  }

  /// Acknowledge tag removal after successful write.
  /// Call this when the user confirms they've removed the tag.
  void acknowledgeTagRemoval() {
    final current = state;
    if (current is NfcSessionWriteSuccess && current.waitingForRemoval) {
      state = NfcSessionWriteSuccess(
        tagInfo: current.tagInfo,
        bytesWritten: current.bytesWritten,
        waitingForRemoval: false,
      );
    }
  }

  /// Reset to idle state.
  void reset() {
    stopSession();
  }

  @override
  void dispose() {
    stopSession();
    super.dispose();
  }
}

/// Provider for NFC session state.
final nfcSessionProvider =
    StateNotifierProvider<NfcSessionNotifier, NfcSessionState>((ref) {
  return NfcSessionNotifier();
});

/// Provider for the last read chunk (persists across session resets).
final lastReadChunkProvider = StateProvider<Chunk?>((ref) => null);

/// Provider for the last tag info (persists across session resets).
final lastTagInfoProvider = StateProvider<NfcTagInfo?>((ref) => null);
