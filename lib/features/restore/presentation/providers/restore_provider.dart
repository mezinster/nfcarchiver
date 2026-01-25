import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chunk.dart';
import '../../data/restore_repository.dart';

/// State for restore scanning process.
sealed class RestoreState {
  const RestoreState();
}

/// Initial state - not scanning.
class RestoreInitial extends RestoreState {
  const RestoreInitial();
}

/// Actively scanning for tags.
class RestoreScanning extends RestoreState {
  const RestoreScanning({
    this.sessions = const [],
    this.lastScannedChunk,
    this.lastError,
  });

  final List<RestoreSessionInfo> sessions;
  final ScannedChunkInfo? lastScannedChunk;
  final String? lastError;
}

/// Archive is complete, ready to restore.
class RestoreReady extends RestoreState {
  const RestoreReady({
    required this.session,
    this.needsPassword = false,
  });

  final RestoreSession session;
  final bool needsPassword;
}

/// Restoring the archive.
class RestoreInProgress extends RestoreState {
  const RestoreInProgress({
    required this.archiveId,
    this.stage = 'Restoring...',
  });

  final String archiveId;
  final String stage;
}

/// Archive restored successfully.
class RestoreComplete extends RestoreState {
  const RestoreComplete({
    required this.result,
    required this.fileName,
  });

  final RestoreResult result;
  final String fileName;
}

/// Error during restore.
class RestoreError extends RestoreState {
  const RestoreError({
    required this.message,
    this.canRetry = true,
  });

  final String message;
  final bool canRetry;
}

/// Information about a scanned chunk.
class ScannedChunkInfo {
  const ScannedChunkInfo({
    required this.archiveId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.isNew,
  });

  final String archiveId;
  final int chunkIndex;
  final int totalChunks;
  final bool isNew;
}

/// Summary info about a restore session.
class RestoreSessionInfo {
  const RestoreSessionInfo({
    required this.archiveId,
    required this.receivedCount,
    required this.totalChunks,
    required this.isComplete,
    required this.isEncrypted,
  });

  final String archiveId;
  final int receivedCount;
  final int totalChunks;
  final bool isComplete;
  final bool isEncrypted;

  double get progress => totalChunks > 0 ? receivedCount / totalChunks : 0.0;
}

/// Notifier for restore state management.
class RestoreNotifier extends StateNotifier<RestoreState> {
  RestoreNotifier() : super(const RestoreInitial());

  final _repository = RestoreRepository.instance;

  /// Start scanning for tags.
  void startScanning() {
    state = RestoreScanning(
      sessions: _getSessionInfos(),
    );
  }

  /// Process a scanned chunk.
  void processChunk(Chunk chunk) {
    final session = _repository.addChunk(chunk);
    final isNew = session.hasChunk(chunk.chunkIndex);

    final info = ScannedChunkInfo(
      archiveId: session.archiveIdString,
      chunkIndex: chunk.chunkIndex,
      totalChunks: chunk.totalChunks,
      isNew: isNew,
    );

    if (session.isComplete) {
      // Archive complete!
      state = RestoreReady(
        session: session,
        needsPassword: session.isEncrypted,
      );
    } else {
      state = RestoreScanning(
        sessions: _getSessionInfos(),
        lastScannedChunk: info,
      );
    }
  }

  /// Handle scan error.
  void scanError(String message) {
    final current = state;
    if (current is RestoreScanning) {
      state = RestoreScanning(
        sessions: current.sessions,
        lastScannedChunk: current.lastScannedChunk,
        lastError: message,
      );
    }
  }

  /// Select a session to restore (if multiple archives detected).
  void selectSession(RestoreSession session) {
    if (session.isComplete) {
      state = RestoreReady(
        session: session,
        needsPassword: session.isEncrypted,
      );
    }
  }

  /// Restore the archive.
  Future<void> restoreArchive({
    String? password,
    String? fileName,
  }) async {
    final current = state;
    if (current is! RestoreReady) return;

    state = RestoreInProgress(
      archiveId: current.session.archiveIdString,
      stage: 'Assembling data...',
    );

    try {
      final result = await _repository.restoreArchive(
        session: current.session,
        password: password,
      );

      // Save to downloads
      final actualFileName = fileName ?? 'restored_file';
      final savedPath = await _repository.saveToDownloads(
        result.data,
        actualFileName,
      );

      state = RestoreComplete(
        result: RestoreResult(
          data: result.data,
          savedPath: savedPath,
          wasEncrypted: result.wasEncrypted,
          wasCompressed: result.wasCompressed,
          totalChunks: result.totalChunks,
        ),
        fileName: actualFileName,
      );
    } on RestoreException catch (e) {
      state = RestoreError(message: e.message);
    } catch (e) {
      state = RestoreError(message: e.toString());
    }
  }

  /// Get session by archive ID.
  RestoreSession? getSession(String archiveId) {
    return _repository.getSessionByIdString(archiveId);
  }

  /// Reset to initial state.
  void reset() {
    _repository.clearAllSessions();
    state = const RestoreInitial();
  }

  /// Go back to scanning (from ready state).
  void backToScanning() {
    state = RestoreScanning(
      sessions: _getSessionInfos(),
    );
  }

  List<RestoreSessionInfo> _getSessionInfos() {
    return _repository.activeSessions
        .map((s) => RestoreSessionInfo(
              archiveId: s.archiveIdString,
              receivedCount: s.receivedCount,
              totalChunks: s.totalChunks,
              isComplete: s.isComplete,
              isEncrypted: s.isEncrypted,
            ))
        .toList();
  }
}

/// Provider for restore state.
final restoreProvider =
    StateNotifierProvider<RestoreNotifier, RestoreState>((ref) {
  return RestoreNotifier();
});
