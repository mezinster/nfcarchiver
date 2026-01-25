import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chunk.dart';
import '../../../../core/services/chunker_service.dart';
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
    this.session,
    this.corruptedChunks = const [],
  });

  final String message;
  final bool canRetry;
  /// Session preserved for retry (if available)
  final RestoreSession? session;
  /// Indices of chunks with CRC errors
  final List<int> corruptedChunks;

  bool get hasCorruptedChunks => corruptedChunks.isNotEmpty;
  bool get isDecryptionError => message.contains('Decryption failed');
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
    final session = _repository.getSession(chunk.archiveId);

    // Check if this chunk already exists
    final existingChunk = session.chunks[chunk.chunkIndex];
    bool isNew = existingChunk == null;
    bool isReplacement = false;

    if (existingChunk != null) {
      // Check if existing chunk is corrupted - if so, replace it
      final existingValid = ChunkerService.instance.validateChunk(existingChunk);
      final newValid = ChunkerService.instance.validateChunk(chunk);

      if (!existingValid && newValid) {
        // Replace corrupted chunk with valid one
        session.replaceChunk(chunk);
        isReplacement = true;
      }
      // If existing is valid, ignore the new scan (duplicate)
    } else {
      // New chunk
      session.addChunk(chunk);
    }

    final info = ScannedChunkInfo(
      archiveId: session.archiveIdString,
      chunkIndex: chunk.chunkIndex,
      totalChunks: chunk.totalChunks,
      isNew: isNew || isReplacement,
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

    final session = current.session;

    state = RestoreInProgress(
      archiveId: session.archiveIdString,
      stage: 'Validating chunks...',
    );

    // Check for CRC errors first
    final corruptedChunks = session.getCorruptedChunkIndices();
    if (corruptedChunks.isNotEmpty) {
      state = RestoreError(
        message: 'CRC validation failed for ${corruptedChunks.length} chunk(s): '
            '${corruptedChunks.map((i) => '#${i + 1}').join(', ')}. '
            'Please rescan these tags.',
        canRetry: true,
        session: session,
        corruptedChunks: corruptedChunks,
      );
      return;
    }

    state = RestoreInProgress(
      archiveId: session.archiveIdString,
      stage: 'Assembling data...',
    );

    try {
      final result = await _repository.restoreArchive(
        session: session,
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
      // Preserve session for retry
      state = RestoreError(
        message: e.message,
        canRetry: true,
        session: session,
      );
    } catch (e) {
      state = RestoreError(
        message: e.toString(),
        canRetry: true,
        session: session,
      );
    }
  }

  /// Get session by archive ID.
  RestoreSession? getSession(String archiveId) {
    return _repository.getSessionByIdString(archiveId);
  }

  /// Retry restore from error state (preserves session).
  void retryRestore() {
    final current = state;
    if (current is RestoreError && current.session != null) {
      state = RestoreReady(
        session: current.session!,
        needsPassword: current.session!.isEncrypted,
      );
    }
  }

  /// Go back to scanning to rescan specific corrupted chunks.
  void rescanCorruptedChunks() {
    final current = state;
    if (current is RestoreError && current.session != null) {
      state = RestoreScanning(
        sessions: _getSessionInfos(),
        lastError: 'Rescan tags for chunks: ${current.corruptedChunks.map((i) => '#${i + 1}').join(', ')}',
      );
    }
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
