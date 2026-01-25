import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/nfar_format.dart';
import '../../../../core/models/chunk.dart';
import '../../data/archive_repository.dart';

/// State for archive creation process.
sealed class ArchiveState {
  const ArchiveState();
}

/// Initial state - no file selected.
class ArchiveInitial extends ArchiveState {
  const ArchiveInitial();
}

/// File selected, ready to configure.
class ArchiveFileSelected extends ArchiveState {
  const ArchiveFileSelected({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
  });

  final String filePath;
  final String fileName;
  final int fileSize;
}

/// Configuring archive settings.
class ArchiveConfiguring extends ArchiveState {
  const ArchiveConfiguring({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.tagType,
    required this.compress,
    required this.encrypt,
    this.estimate,
  });

  final String filePath;
  final String fileName;
  final int fileSize;
  final NfcTagType tagType;
  final bool compress;
  final bool encrypt;
  final ArchiveEstimate? estimate;
}

/// Archive is being prepared (compression, encryption, chunking).
class ArchivePreparing extends ArchiveState {
  const ArchivePreparing({
    required this.fileName,
    this.progress = 0.0,
    this.stage = 'Preparing...',
  });

  final String fileName;
  final double progress;
  final String stage;
}

/// Archive prepared, ready to write to tags.
class ArchiveReady extends ArchiveState {
  const ArchiveReady({
    required this.result,
    required this.currentChunkIndex,
    required this.writtenChunks,
  });

  final ArchiveResult result;
  final int currentChunkIndex;
  final Set<int> writtenChunks;

  int get totalChunks => result.chunks.length;
  int get writtenCount => writtenChunks.length;
  double get progress => totalChunks > 0 ? writtenCount / totalChunks : 0.0;
  bool get isComplete => writtenCount >= totalChunks;
  Chunk get currentChunk => result.chunks[currentChunkIndex];
  int get remainingCount => totalChunks - writtenCount;
}

/// Writing a chunk to a tag.
class ArchiveWriting extends ArchiveState {
  const ArchiveWriting({
    required this.result,
    required this.currentChunkIndex,
    required this.writtenChunks,
  });

  final ArchiveResult result;
  final int currentChunkIndex;
  final Set<int> writtenChunks;

  int get totalChunks => result.chunks.length;
  double get progress => totalChunks > 0 ? writtenChunks.length / totalChunks : 0.0;
}

/// All chunks written successfully.
class ArchiveComplete extends ArchiveState {
  const ArchiveComplete({
    required this.result,
    required this.totalTags,
  });

  final ArchiveResult result;
  final int totalTags;
}

/// Error during archive process.
class ArchiveError extends ArchiveState {
  const ArchiveError({
    required this.message,
    this.canRetry = true,
  });

  final String message;
  final bool canRetry;
}

/// Notifier for archive creation state.
class ArchiveNotifier extends StateNotifier<ArchiveState> {
  ArchiveNotifier() : super(const ArchiveInitial());

  final _repository = ArchiveRepository.instance;
  String? _password;

  /// Select a file to archive.
  void selectFile({
    required String filePath,
    required String fileName,
    required int fileSize,
  }) {
    state = ArchiveFileSelected(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
    );
  }

  /// Configure archive settings.
  void configure({
    required NfcTagType tagType,
    bool compress = false,
    bool encrypt = false,
  }) {
    final current = state;
    if (current is! ArchiveFileSelected && current is! ArchiveConfiguring) {
      return;
    }

    String filePath;
    String fileName;
    int fileSize;

    if (current is ArchiveFileSelected) {
      filePath = current.filePath;
      fileName = current.fileName;
      fileSize = current.fileSize;
    } else {
      final config = current as ArchiveConfiguring;
      filePath = config.filePath;
      fileName = config.fileName;
      fileSize = config.fileSize;
    }

    // Get estimate
    final estimate = _repository.estimateFromSize(
      dataSize: fileSize,
      tagType: tagType,
      compress: compress,
      encrypt: encrypt,
    );

    state = ArchiveConfiguring(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      tagType: tagType,
      compress: compress,
      encrypt: encrypt,
      estimate: estimate,
    );
  }

  /// Set the password for encryption.
  void setPassword(String? password) {
    _password = password;
  }

  /// Prepare the archive (compress, encrypt, chunk).
  Future<void> prepareArchive() async {
    final current = state;
    if (current is! ArchiveConfiguring) return;

    state = ArchivePreparing(
      fileName: current.fileName,
      stage: 'Reading file...',
    );

    try {
      final result = await _repository.createArchive(
        filePath: current.filePath,
        tagType: current.tagType,
        compress: current.compress,
        password: current.encrypt ? _password : null,
      );

      state = ArchiveReady(
        result: result,
        currentChunkIndex: 0,
        writtenChunks: const {},
      );
    } catch (e) {
      state = ArchiveError(message: e.toString());
    }
  }

  /// Mark the current chunk as written and move to next.
  void markChunkWritten() {
    final current = state;
    if (current is! ArchiveReady && current is! ArchiveWriting) return;

    ArchiveResult result;
    int currentIndex;
    Set<int> written;

    if (current is ArchiveReady) {
      result = current.result;
      currentIndex = current.currentChunkIndex;
      written = current.writtenChunks;
    } else {
      final writing = current as ArchiveWriting;
      result = writing.result;
      currentIndex = writing.currentChunkIndex;
      written = writing.writtenChunks;
    }

    final newWritten = {...written, currentIndex};

    if (newWritten.length >= result.chunks.length) {
      // All done!
      state = ArchiveComplete(
        result: result,
        totalTags: result.chunks.length,
      );
      return;
    }

    // Find next unwritten chunk
    int nextIndex = (currentIndex + 1) % result.chunks.length;
    while (newWritten.contains(nextIndex)) {
      nextIndex = (nextIndex + 1) % result.chunks.length;
    }

    state = ArchiveReady(
      result: result,
      currentChunkIndex: nextIndex,
      writtenChunks: newWritten,
    );
  }

  /// Start writing the current chunk.
  void startWriting() {
    final current = state;
    if (current is! ArchiveReady) return;

    state = ArchiveWriting(
      result: current.result,
      currentChunkIndex: current.currentChunkIndex,
      writtenChunks: current.writtenChunks,
    );
  }

  /// Cancel writing and return to ready state.
  void cancelWriting() {
    final current = state;
    if (current is! ArchiveWriting) return;

    state = ArchiveReady(
      result: current.result,
      currentChunkIndex: current.currentChunkIndex,
      writtenChunks: current.writtenChunks,
    );
  }

  /// Handle write error.
  void writeError(String message) {
    final current = state;
    if (current is! ArchiveWriting) return;

    // Return to ready state so user can retry
    state = ArchiveReady(
      result: current.result,
      currentChunkIndex: current.currentChunkIndex,
      writtenChunks: current.writtenChunks,
    );
  }

  /// Reset to initial state.
  void reset() {
    _password = null;
    state = const ArchiveInitial();
  }
}

/// Provider for archive state.
final archiveProvider =
    StateNotifierProvider<ArchiveNotifier, ArchiveState>((ref) {
  return ArchiveNotifier();
});

/// Provider for selected tag type.
final selectedTagTypeProvider = StateProvider<NfcTagType>((ref) {
  return NfcTagType.ntag216;
});

/// Provider for compression setting.
final compressionEnabledProvider = StateProvider<bool>((ref) => false);

/// Provider for encryption setting.
final encryptionEnabledProvider = StateProvider<bool>((ref) => false);
