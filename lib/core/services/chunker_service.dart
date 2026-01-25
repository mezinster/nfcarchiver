import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../constants/nfar_format.dart';
import '../models/archive_metadata.dart';
import '../models/chunk.dart';
import 'checksum_service.dart';

/// Service for splitting data into chunks and reassembling them.
class ChunkerService {
  /// Singleton instance
  static final ChunkerService instance = ChunkerService._();

  ChunkerService._();

  final _uuid = const Uuid();
  final _checksumService = ChecksumService.instance;

  /// Split data into chunks for storage on NFC tags.
  ///
  /// [data] - The data to split
  /// [tagType] - The type of NFC tag to target (determines chunk size)
  /// [flags] - Flags indicating compression/encryption
  ///
  /// Returns a tuple of (ArchiveMetadata, List<Chunk>)
  ({ArchiveMetadata metadata, List<Chunk> chunks}) createChunks({
    required Uint8List data,
    required NfcTagType tagType,
    int flags = 0,
  }) {
    final payloadSize = tagType.maxPayloadSize;
    if (payloadSize <= 0) {
      throw ArgumentError(
        'Tag type ${tagType.name} has no usable payload space',
      );
    }

    // Generate archive ID
    final archiveIdBytes = _generateArchiveId();

    // Calculate number of chunks
    final totalChunks = (data.length + payloadSize - 1) ~/ payloadSize;
    if (totalChunks > NfarLimits.maxChunks) {
      throw ArgumentError(
        'Data too large: would need $totalChunks chunks, '
        'maximum is ${NfarLimits.maxChunks}',
      );
    }

    // Create chunks
    final chunks = <Chunk>[];
    int offset = 0;

    for (int i = 0; i < totalChunks; i++) {
      final remaining = data.length - offset;
      final chunkSize = remaining < payloadSize ? remaining : payloadSize;
      final payload = Uint8List.sublistView(data, offset, offset + chunkSize);
      final crc = _checksumService.calculate(payload);

      chunks.add(Chunk(
        archiveId: archiveIdBytes,
        totalChunks: totalChunks,
        chunkIndex: i,
        payload: payload,
        crc32: crc,
        flags: flags,
      ));

      offset += chunkSize;
    }

    // Create metadata
    final metadata = ArchiveMetadata(
      id: archiveIdBytes,
      originalFileName: '',
      originalSize: data.length,
      totalChunks: totalChunks,
      chunkPayloadSize: payloadSize,
      isCompressed: NfarFlags.isCompressed(flags),
      isEncrypted: NfarFlags.isEncrypted(flags),
      createdAt: DateTime.now(),
    );

    return (metadata: metadata, chunks: chunks);
  }

  /// Split data with custom payload size.
  ({ArchiveMetadata metadata, List<Chunk> chunks}) createChunksWithSize({
    required Uint8List data,
    required int payloadSize,
    int flags = 0,
    String fileName = '',
  }) {
    if (payloadSize <= 0) {
      throw ArgumentError('Payload size must be positive');
    }
    if (payloadSize > NfarLimits.maxPayloadSize) {
      throw ArgumentError(
        'Payload size too large: $payloadSize > ${NfarLimits.maxPayloadSize}',
      );
    }

    final archiveIdBytes = _generateArchiveId();
    final totalChunks = (data.length + payloadSize - 1) ~/ payloadSize;

    if (totalChunks > NfarLimits.maxChunks) {
      throw ArgumentError(
        'Data too large: would need $totalChunks chunks',
      );
    }

    final chunks = <Chunk>[];
    int offset = 0;

    for (int i = 0; i < totalChunks; i++) {
      final remaining = data.length - offset;
      final chunkSize = remaining < payloadSize ? remaining : payloadSize;
      final payload = Uint8List.sublistView(data, offset, offset + chunkSize);
      final crc = _checksumService.calculate(payload);

      chunks.add(Chunk(
        archiveId: archiveIdBytes,
        totalChunks: totalChunks,
        chunkIndex: i,
        payload: payload,
        crc32: crc,
        flags: flags,
      ));

      offset += chunkSize;
    }

    final metadata = ArchiveMetadata(
      id: archiveIdBytes,
      originalFileName: fileName,
      originalSize: data.length,
      totalChunks: totalChunks,
      chunkPayloadSize: payloadSize,
      isCompressed: NfarFlags.isCompressed(flags),
      isEncrypted: NfarFlags.isEncrypted(flags),
      createdAt: DateTime.now(),
    );

    return (metadata: metadata, chunks: chunks);
  }

  /// Reassemble chunks into original data.
  ///
  /// [chunks] must be a complete set of chunks from the same archive.
  /// Throws [ArgumentError] if chunks are missing or from different archives.
  Uint8List assembleChunks(List<Chunk> chunks) {
    if (chunks.isEmpty) {
      throw ArgumentError('No chunks provided');
    }

    // Sort by index
    final sorted = List<Chunk>.from(chunks)
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

    // Validate archive ID consistency
    final archiveId = sorted.first.archiveId;
    final totalChunks = sorted.first.totalChunks;

    for (final chunk in sorted) {
      if (!_compareBytes(chunk.archiveId, archiveId)) {
        throw ArgumentError(
          'Chunks are from different archives: '
          '${sorted.first.archiveIdString} vs ${chunk.archiveIdString}',
        );
      }
      if (chunk.totalChunks != totalChunks) {
        throw ArgumentError(
          'Inconsistent total chunks: $totalChunks vs ${chunk.totalChunks}',
        );
      }
    }

    // Check for missing chunks
    final indices = sorted.map((c) => c.chunkIndex).toSet();
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!indices.contains(i)) {
        missing.add(i);
      }
    }
    if (missing.isNotEmpty) {
      throw ArgumentError('Missing chunks: $missing');
    }

    // Check for duplicates
    if (sorted.length != totalChunks) {
      throw ArgumentError(
        'Duplicate chunks detected: have ${sorted.length}, expected $totalChunks',
      );
    }

    // Verify CRC for each chunk
    for (final chunk in sorted) {
      if (!_checksumService.verify(chunk.payload, chunk.crc32)) {
        throw ArgumentError(
          'CRC mismatch for chunk ${chunk.chunkIndex}: '
          'data may be corrupted',
        );
      }
    }

    // Calculate total size
    int totalSize = 0;
    for (final chunk in sorted) {
      totalSize += chunk.payload.length;
    }

    // Assemble data
    final result = Uint8List(totalSize);
    int offset = 0;
    for (final chunk in sorted) {
      result.setRange(offset, offset + chunk.payload.length, chunk.payload);
      offset += chunk.payload.length;
    }

    return result;
  }

  /// Validate a single chunk's integrity.
  bool validateChunk(Chunk chunk) {
    return _checksumService.verify(chunk.payload, chunk.crc32);
  }

  /// Generate a new archive UUID.
  Uint8List _generateArchiveId() {
    final uuidString = _uuid.v4();
    // Parse UUID string to bytes
    final hex = uuidString.replaceAll('-', '');
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Compare two byte arrays for equality.
  bool _compareBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Extension for easy access
extension ChunkerExtension on Uint8List {
  /// Split this data into chunks.
  ({ArchiveMetadata metadata, List<Chunk> chunks}) toChunks({
    required NfcTagType tagType,
    int flags = 0,
  }) {
    return ChunkerService.instance.createChunks(
      data: this,
      tagType: tagType,
      flags: flags,
    );
  }
}
