import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../constants/nfar_format.dart';

/// Metadata about an archive being created or restored.
class ArchiveMetadata extends Equatable {
  /// Creates archive metadata.
  const ArchiveMetadata({
    required this.id,
    required this.originalFileName,
    required this.originalSize,
    required this.totalChunks,
    required this.chunkPayloadSize,
    this.isCompressed = false,
    this.isEncrypted = false,
    this.createdAt,
    this.contentHash,
  });

  /// UUID of the archive (16 bytes)
  final Uint8List id;

  /// Original file name
  final String originalFileName;

  /// Original file size in bytes (before compression/encryption)
  final int originalSize;

  /// Total number of chunks
  final int totalChunks;

  /// Size of payload per chunk
  final int chunkPayloadSize;

  /// Whether the data is compressed
  final bool isCompressed;

  /// Whether the data is encrypted
  final bool isEncrypted;

  /// When the archive was created
  final DateTime? createdAt;

  /// SHA-256 hash of the original content (for verification after restore)
  final Uint8List? contentHash;

  /// Archive ID as UUID string
  String get idString {
    final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Flags byte for NFAR format
  int get flags => NfarFlags.create(
        compress: isCompressed,
        encrypt: isEncrypted,
      );

  /// Estimated total size on tags (including headers)
  int get estimatedTagSize {
    final headerPerChunk = NfarHeaderSize.total;
    return totalChunks * (headerPerChunk + chunkPayloadSize);
  }

  /// Create a copy with updated fields.
  ArchiveMetadata copyWith({
    Uint8List? id,
    String? originalFileName,
    int? originalSize,
    int? totalChunks,
    int? chunkPayloadSize,
    bool? isCompressed,
    bool? isEncrypted,
    DateTime? createdAt,
    Uint8List? contentHash,
  }) {
    return ArchiveMetadata(
      id: id ?? this.id,
      originalFileName: originalFileName ?? this.originalFileName,
      originalSize: originalSize ?? this.originalSize,
      totalChunks: totalChunks ?? this.totalChunks,
      chunkPayloadSize: chunkPayloadSize ?? this.chunkPayloadSize,
      isCompressed: isCompressed ?? this.isCompressed,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      createdAt: createdAt ?? this.createdAt,
      contentHash: contentHash ?? this.contentHash,
    );
  }

  @override
  List<Object?> get props => [
        id,
        originalFileName,
        originalSize,
        totalChunks,
        chunkPayloadSize,
        isCompressed,
        isEncrypted,
        createdAt,
        contentHash,
      ];

  @override
  String toString() => 'ArchiveMetadata('
      'id: ${idString.substring(0, 8)}..., '
      'file: $originalFileName, '
      'size: $originalSize, '
      'chunks: $totalChunks)';
}

/// State of archive restoration process.
class RestoreState extends Equatable {
  /// Creates a restore state.
  const RestoreState({
    required this.archiveId,
    required this.totalChunks,
    required this.receivedChunks,
    this.flags = 0,
  });

  /// UUID of the archive being restored
  final Uint8List archiveId;

  /// Total number of chunks expected
  final int totalChunks;

  /// Map of chunk index to chunk data
  final Map<int, Uint8List> receivedChunks;

  /// Flags from the first chunk
  final int flags;

  /// Number of chunks received
  int get receivedCount => receivedChunks.length;

  /// Progress as a fraction (0.0 to 1.0)
  double get progress =>
      totalChunks > 0 ? receivedCount / totalChunks : 0.0;

  /// Whether all chunks have been received
  bool get isComplete => receivedCount >= totalChunks;

  /// List of missing chunk indices
  List<int> get missingIndices {
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!receivedChunks.containsKey(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  /// Whether the data is compressed
  bool get isCompressed => NfarFlags.isCompressed(flags);

  /// Whether the data is encrypted
  bool get isEncrypted => NfarFlags.isEncrypted(flags);

  /// Archive ID as UUID string
  String get archiveIdString {
    final hex = archiveId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Add a chunk to the state.
  RestoreState addChunk(int index, Uint8List data, {int? chunkFlags}) {
    final newChunks = Map<int, Uint8List>.from(receivedChunks);
    newChunks[index] = data;
    return RestoreState(
      archiveId: archiveId,
      totalChunks: totalChunks,
      receivedChunks: newChunks,
      flags: chunkFlags ?? flags,
    );
  }

  /// Assemble all chunks into a single byte array.
  ///
  /// Throws [StateError] if not all chunks are received.
  Uint8List assemble() {
    if (!isComplete) {
      throw StateError(
        'Cannot assemble: missing ${totalChunks - receivedCount} chunks',
      );
    }

    // Calculate total size
    int totalSize = 0;
    for (int i = 0; i < totalChunks; i++) {
      totalSize += receivedChunks[i]!.length;
    }

    // Assemble in order
    final result = Uint8List(totalSize);
    int offset = 0;
    for (int i = 0; i < totalChunks; i++) {
      final chunk = receivedChunks[i]!;
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    return result;
  }

  @override
  List<Object?> get props => [archiveId, totalChunks, receivedChunks, flags];

  @override
  String toString() => 'RestoreState('
      'archive: ${archiveIdString.substring(0, 8)}..., '
      'progress: $receivedCount/$totalChunks)';
}
