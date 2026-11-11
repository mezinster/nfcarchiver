import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/nfar_format.dart';
import '../../../../core/log/logger.dart';
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

/// Text selected, ready to configure.
class ArchiveTextSelected extends ArchiveState {
  const ArchiveTextSelected({
    required this.text,
    required this.textSize,
  });

  final String text;
  final int textSize;

  String get fileName => 'text_note.txt';
}

/// Configuring archive settings.
class ArchiveConfiguring extends ArchiveState {
  const ArchiveConfiguring({
    this.filePath,
    this.textContent,
    required this.fileName,
    required this.fileSize,
    required this.tagType,
    required this.compress,
    required this.encrypt,
    this.estimate,
  });

  /// File path (null if text mode).
  final String? filePath;
  /// Text content (null if file mode).
  final String? textContent;
  final String fileName;
  final int fileSize;
  final NfcTagType tagType;
  final bool compress;
  final bool encrypt;
  final ArchiveEstimate? estimate;

  bool get isTextMode => textContent != null;
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
    this.message,
    this.canRetry = true,
  });

  /// App-authored text only ([ArchiveException.message]). Null means an
  /// unexpected failure: the cause is in the diagnostics log and the screen
  /// shows the localized generic message.
  final String? message;
  final bool canRetry;
}

/// Breadcrumb fields for the log, built per state class from an explicit
/// allow-list: sizes, counts, tag type, option flags, archive ID. Never a file
/// name, path, password, text content or message text (an error message can
/// embed a path). A state class not listed here logs nothing.
Map<String, Object?>? _breadcrumbData(ArchiveState s) {
  Map<String, Object?> chunks(ArchiveResult r, int index, Set<int> written) => {
        if (r.chunks.isNotEmpty) 'archiveId': r.chunks.first.archiveIdString,
        'chunk': index,
        'chunks': r.chunks.length,
        'written': written.length,
        'originalSize': r.originalSize,
        'processedSize': r.processedSize,
        'compressed': r.wasCompressed,
        'encrypted': r.wasEncrypted,
      };
  return switch (s) {
    ArchiveFileSelected() => {'size': s.fileSize},
    ArchiveTextSelected() => {'size': s.textSize},
    ArchiveConfiguring() => {
        'size': s.fileSize,
        'tagType': s.tagType.name,
        'compress': s.compress,
        'encrypt': s.encrypt,
        'text': s.isTextMode,
      },
    ArchiveReady() => chunks(s.result, s.currentChunkIndex, s.writtenChunks),
    ArchiveWriting() => chunks(s.result, s.currentChunkIndex, s.writtenChunks),
    ArchiveComplete() => {
        if (s.result.chunks.isNotEmpty)
          'archiveId': s.result.chunks.first.archiveIdString,
        'tags': s.totalTags,
      },
    ArchiveError() => {'hasMessage': s.message != null, 'canRetry': s.canRetry},
    ArchiveInitial() || ArchivePreparing() => null,
  };
}

/// Notifier for archive creation state.
class ArchiveNotifier extends StateNotifier<ArchiveState> {
  ArchiveNotifier({ArchiveRepository? repository})
      : _repository = repository ?? ArchiveRepository.instance,
        super(const ArchiveInitial());

  final ArchiveRepository _repository;
  String? _password;
  NfcTagType? _configuredTagType;

  /// The medium the archive was configured for, or null before one is
  /// prepared. A re-chunk must size payloads for this medium: the phone
  /// radio reports no tag type for a Mifare Classic card, so the tapped
  /// tag's own info cannot be trusted to say.
  TagMedium? get configuredMedium => _configuredTagType?.medium;

  /// Every transition leaves a breadcrumb. Emitted per user-visible step
  /// (select, configure, prepare, one chunk written), never per tick.
  @override
  set state(ArchiveState value) {
    log.info('archive', 'state ${value.runtimeType}', _breadcrumbData(value));
    super.state = value;
  }

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

  /// Select text to archive.
  void selectText({
    required String text,
    required int textSize,
  }) {
    state = ArchiveTextSelected(
      text: text,
      textSize: textSize,
    );
  }

  /// Configure archive settings.
  void configure({
    required NfcTagType tagType,
    bool compress = false,
    bool encrypt = false,
  }) {
    final current = state;
    if (current is! ArchiveFileSelected &&
        current is! ArchiveTextSelected &&
        current is! ArchiveConfiguring) {
      return;
    }

    String? filePath;
    String? textContent;
    String fileName;
    int fileSize;

    if (current is ArchiveFileSelected) {
      filePath = current.filePath;
      fileName = current.fileName;
      fileSize = current.fileSize;
    } else if (current is ArchiveTextSelected) {
      textContent = current.text;
      fileName = current.fileName;
      fileSize = current.textSize;
    } else {
      final config = current as ArchiveConfiguring;
      filePath = config.filePath;
      textContent = config.textContent;
      fileName = config.fileName;
      fileSize = config.fileSize;
    }

    // Get estimate
    final estimate = _repository.estimateFromSize(
      dataSize: fileSize,
      fileName: fileName,
      tagType: tagType,
      compress: compress,
      encrypt: encrypt,
    );

    state = ArchiveConfiguring(
      filePath: filePath,
      textContent: textContent,
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
      stage: current.isTextMode ? 'Processing text...' : 'Reading file...',
    );

    try {
      ArchiveResult result;

      if (current.isTextMode) {
        // Text mode: encode text as UTF-8 bytes
        final textBytes = Uint8List.fromList(utf8.encode(current.textContent!));
        result = await _repository.createArchiveFromBytes(
          data: textBytes,
          fileName: current.fileName,
          tagType: current.tagType,
          compress: current.compress,
          password: current.encrypt ? _password : null,
        );
      } else {
        // File mode: read from file path
        result = await _repository.createArchive(
          filePath: current.filePath!,
          tagType: current.tagType,
          compress: current.compress,
          password: current.encrypt ? _password : null,
        );
      }

      _configuredTagType = current.tagType;
      state = ArchiveReady(
        result: result,
        currentChunkIndex: 0,
        writtenChunks: const {},
      );
    } on ArchiveException catch (e) {
      state = ArchiveError(message: e.message);
    } catch (e, st) {
      log.report('archive', 'prepare failed', e, st);
      state = const ArchiveError();
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

  /// Re-chunk the archive for a detected tag capacity.
  ///
  /// Call this when a tag is detected with less capacity than expected.
  /// Returns the new number of chunks needed, or null if rechunking failed.
  int? rechunkForDetectedCapacity(
    int detectedCapacity, {
    TagMedium medium = TagMedium.ndef,
  }) {
    final current = state;
    ArchiveResult? result;
    Set<int> writtenChunks = const {};

    if (current is ArchiveReady) {
      result = current.result;
      writtenChunks = current.writtenChunks;
    } else if (current is ArchiveWriting) {
      result = current.result;
      writtenChunks = current.writtenChunks;
    }

    if (result == null) return null;

    // Don't rechunk if we've already written some chunks
    // (would invalidate the archive)
    if (writtenChunks.isNotEmpty) return null;

    try {
      // Calculate max payload for the detected capacity
      final newPayloadSize = NfcTagType.payloadForCapacity(detectedCapacity, medium);

      if (newPayloadSize <= 0) {
        return null; // Tag too small for any data
      }

      // Re-chunk with new payload size
      final newResult = _repository.rechunkForCapacity(
        existingResult: result,
        newPayloadSize: newPayloadSize,
      );

      state = ArchiveReady(
        result: newResult,
        currentChunkIndex: 0,
        writtenChunks: const {},
      );

      return newResult.chunks.length;
    } catch (e, st) {
      log.report('archive', 'rechunk failed', e, st);
      return null;
    }
  }

  /// Get the current chunk's required NDEF size.
  int? getCurrentChunkNdefSize() {
    final current = state;
    if (current is ArchiveReady) {
      return current.currentChunk.totalSize + 39; // chunk bytes + NDEF overhead
    }
    return null;
  }

  /// Reset to initial state.
  void reset() {
    _password = null;
    _configuredTagType = null;
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
