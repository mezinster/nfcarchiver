import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/archive_metadata.dart';
import '../../../core/models/chunk.dart';
import '../../../core/services/chunker_service.dart';
import '../../../core/services/compression_service.dart';
import '../../../core/services/encryption_service.dart';

/// Repository for archive creation operations.
class ArchiveRepository {
  /// Singleton instance
  static final ArchiveRepository instance = ArchiveRepository._();

  ArchiveRepository._();

  final _chunkerService = ChunkerService.instance;
  final _compressionService = CompressionService.instance;
  final _encryptionService = EncryptionService.instance;

  /// Prepare an archive from a file.
  ///
  /// Returns the metadata and chunks ready for writing to NFC tags.
  Future<ArchiveResult> createArchive({
    required String filePath,
    required NfcTagType tagType,
    bool compress = false,
    String? password,
  }) async {
    // Read file
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArchiveException('File not found: $filePath');
    }

    final fileName = path.basename(filePath);
    var data = await file.readAsBytes();
    final originalSize = data.length;

    // Prepend filename metadata to data
    // Format: [2-byte length (big-endian)][UTF-8 filename bytes][original data]
    data = _prependFilenameMetadata(data, fileName);

    // Compress if requested
    bool wasCompressed = false;
    if (compress) {
      final result = _compressionService.compressIfSmaller(data);
      data = result.data;
      wasCompressed = result.wasCompressed;
    }

    // Encrypt if password provided
    bool wasEncrypted = false;
    if (password != null && password.isNotEmpty) {
      data = _encryptionService.encrypt(data, password);
      wasEncrypted = true;
    }

    // Create flags
    final flags = NfarFlags.create(
      compress: wasCompressed,
      encrypt: wasEncrypted,
    );

    // Split into chunks
    final result = _chunkerService.createChunksWithSize(
      data: data,
      payloadSize: tagType.maxPayloadSize,
      flags: flags,
      fileName: fileName,
    );

    // Update metadata with file info
    final metadata = result.metadata.copyWith(
      originalFileName: fileName,
      originalSize: originalSize,
    );

    return ArchiveResult(
      metadata: metadata,
      chunks: result.chunks,
      originalSize: originalSize,
      processedSize: data.length,
      wasCompressed: wasCompressed,
      wasEncrypted: wasEncrypted,
      processedData: data,
      fileName: fileName,
      flags: flags,
    );
  }

  /// Re-chunk an existing archive result for a different payload size.
  ///
  /// Use this when the detected tag capacity is different from expected.
  ArchiveResult rechunkForCapacity({
    required ArchiveResult existingResult,
    required int newPayloadSize,
  }) {
    if (newPayloadSize <= 0) {
      throw ArchiveException('Payload size must be positive');
    }
    if (newPayloadSize > NfarLimits.maxPayloadSize) {
      throw ArchiveException(
        'Payload size too large: $newPayloadSize > ${NfarLimits.maxPayloadSize}',
      );
    }

    // Re-chunk with new payload size
    final result = _chunkerService.createChunksWithSize(
      data: existingResult.processedData,
      payloadSize: newPayloadSize,
      flags: existingResult.flags,
      fileName: existingResult.fileName,
    );

    final metadata = result.metadata.copyWith(
      originalFileName: existingResult.fileName,
      originalSize: existingResult.originalSize,
    );

    return ArchiveResult(
      metadata: metadata,
      chunks: result.chunks,
      originalSize: existingResult.originalSize,
      processedSize: existingResult.processedSize,
      wasCompressed: existingResult.wasCompressed,
      wasEncrypted: existingResult.wasEncrypted,
      processedData: existingResult.processedData,
      fileName: existingResult.fileName,
      flags: existingResult.flags,
    );
  }

  /// Prepare an archive from raw bytes.
  Future<ArchiveResult> createArchiveFromBytes({
    required Uint8List data,
    required String fileName,
    required NfcTagType tagType,
    bool compress = false,
    String? password,
  }) async {
    final originalSize = data.length;

    // Prepend filename metadata to data (same as createArchive)
    var processedData = _prependFilenameMetadata(data, fileName);

    // Compress if requested
    bool wasCompressed = false;
    if (compress) {
      final result = _compressionService.compressIfSmaller(processedData);
      processedData = result.data;
      wasCompressed = result.wasCompressed;
    }

    // Encrypt if password provided
    bool wasEncrypted = false;
    if (password != null && password.isNotEmpty) {
      processedData = _encryptionService.encrypt(processedData, password);
      wasEncrypted = true;
    }

    // Create flags
    final flags = NfarFlags.create(
      compress: wasCompressed,
      encrypt: wasEncrypted,
    );

    // Split into chunks
    final result = _chunkerService.createChunksWithSize(
      data: processedData,
      payloadSize: tagType.maxPayloadSize,
      flags: flags,
      fileName: fileName,
    );

    final metadata = result.metadata.copyWith(
      originalFileName: fileName,
      originalSize: originalSize,
    );

    return ArchiveResult(
      metadata: metadata,
      chunks: result.chunks,
      originalSize: originalSize,
      processedSize: processedData.length,
      wasCompressed: wasCompressed,
      wasEncrypted: wasEncrypted,
      processedData: processedData,
      fileName: fileName,
      flags: flags,
    );
  }

  /// Estimate the number of tags needed for a file.
  Future<ArchiveEstimate> estimateArchive({
    required String filePath,
    required NfcTagType tagType,
    bool compress = false,
    bool encrypt = false,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArchiveException('File not found: $filePath');
    }

    final fileSize = await file.length();
    return estimateFromSize(
      dataSize: fileSize,
      tagType: tagType,
      compress: compress,
      encrypt: encrypt,
    );
  }

  /// Estimate tags needed for data of given size.
  ArchiveEstimate estimateFromSize({
    required int dataSize,
    required NfcTagType tagType,
    bool compress = false,
    bool encrypt = false,
  }) {
    var estimatedSize = dataSize;

    // Estimate compression (conservative: assume 70% ratio)
    double compressionRatio = 1.0;
    if (compress) {
      compressionRatio = 0.7;
      estimatedSize = (estimatedSize * compressionRatio).round();
    }

    // Add encryption overhead
    if (encrypt) {
      estimatedSize += EncryptionService.encryptionOverhead;
    }

    final payloadSize = tagType.maxPayloadSize;
    if (payloadSize <= 0) {
      throw ArchiveException('Tag type ${tagType.name} has no usable space');
    }

    final chunksNeeded = (estimatedSize + payloadSize - 1) ~/ payloadSize;

    return ArchiveEstimate(
      originalSize: dataSize,
      estimatedProcessedSize: estimatedSize,
      chunksNeeded: chunksNeeded,
      payloadPerChunk: payloadSize,
      compressionRatio: compressionRatio,
      tagType: tagType,
    );
  }

  /// Validate that archive can be created with given parameters.
  ArchiveValidation validateArchive({
    required int dataSize,
    required NfcTagType tagType,
  }) {
    final estimate = estimateFromSize(
      dataSize: dataSize,
      tagType: tagType,
    );

    if (estimate.chunksNeeded > NfarLimits.maxChunks) {
      return ArchiveValidation(
        isValid: false,
        error: 'Data too large: would need ${estimate.chunksNeeded} tags, '
            'maximum is ${NfarLimits.maxChunks}',
        estimate: estimate,
      );
    }

    if (tagType.maxPayloadSize <= 0) {
      return ArchiveValidation(
        isValid: false,
        error: 'Tag type ${tagType.name} cannot store NFAR data',
        estimate: estimate,
      );
    }

    return ArchiveValidation(
      isValid: true,
      estimate: estimate,
    );
  }

  /// Prepend filename metadata to data.
  /// Format: [2-byte length (big-endian)][UTF-8 filename bytes][original data]
  Uint8List _prependFilenameMetadata(Uint8List data, String fileName) {
    final filenameBytes = utf8.encode(fileName);
    // Limit filename to 255 bytes for safety
    final truncatedFilename = filenameBytes.length > 255
        ? filenameBytes.sublist(0, 255)
        : filenameBytes;

    final result = Uint8List(2 + truncatedFilename.length + data.length);
    // Big-endian length
    result[0] = (truncatedFilename.length >> 8) & 0xFF;
    result[1] = truncatedFilename.length & 0xFF;
    result.setRange(2, 2 + truncatedFilename.length, truncatedFilename);
    result.setRange(2 + truncatedFilename.length, result.length, data);

    return result;
  }
}

/// Extract filename metadata from data.
/// Returns (filename, remaining data) or null if invalid.
({String fileName, Uint8List data})? extractFilenameMetadata(Uint8List data) {
  if (data.length < 2) return null;

  final filenameLength = (data[0] << 8) | data[1];
  if (data.length < 2 + filenameLength) return null;

  try {
    final filenameBytes = data.sublist(2, 2 + filenameLength);
    final fileName = utf8.decode(filenameBytes);
    final remainingData = Uint8List.sublistView(data, 2 + filenameLength);
    return (fileName: fileName, data: remainingData);
  } catch (_) {
    return null;
  }
}

/// Result of archive creation.
class ArchiveResult {
  const ArchiveResult({
    required this.metadata,
    required this.chunks,
    required this.originalSize,
    required this.processedSize,
    required this.wasCompressed,
    required this.wasEncrypted,
    required this.processedData,
    required this.fileName,
    required this.flags,
  });

  final ArchiveMetadata metadata;
  final List<Chunk> chunks;
  final int originalSize;
  final int processedSize;
  final bool wasCompressed;
  final bool wasEncrypted;
  /// Processed data (after compression/encryption) for re-chunking
  final Uint8List processedData;
  /// Original file name
  final String fileName;
  /// NFAR flags
  final int flags;

  /// Compression ratio (1.0 = no compression, 0.5 = 50% size)
  double get compressionRatio =>
      originalSize > 0 ? processedSize / originalSize : 1.0;

  /// Number of chunks/tags needed
  int get tagCount => chunks.length;
}

/// Estimate of archive requirements.
class ArchiveEstimate {
  const ArchiveEstimate({
    required this.originalSize,
    required this.estimatedProcessedSize,
    required this.chunksNeeded,
    required this.payloadPerChunk,
    required this.compressionRatio,
    required this.tagType,
  });

  final int originalSize;
  final int estimatedProcessedSize;
  final int chunksNeeded;
  final int payloadPerChunk;
  final double compressionRatio;
  final NfcTagType tagType;
}

/// Validation result for archive creation.
class ArchiveValidation {
  const ArchiveValidation({
    required this.isValid,
    this.error,
    this.estimate,
  });

  final bool isValid;
  final String? error;
  final ArchiveEstimate? estimate;
}

/// Exception during archive operations.
class ArchiveException implements Exception {
  const ArchiveException(this.message);

  final String message;

  @override
  String toString() => 'ArchiveException: $message';
}
