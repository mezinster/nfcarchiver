import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../constants/nfar_format.dart';
import '../utils/binary_reader.dart';
import '../utils/binary_writer.dart';

/// Represents a single chunk of archive data to be stored on an NFC tag.
class Chunk extends Equatable {
  /// Creates a new chunk.
  const Chunk({
    required this.archiveId,
    required this.totalChunks,
    required this.chunkIndex,
    required this.payload,
    required this.crc32,
    this.flags = 0,
  });

  /// UUID of the archive this chunk belongs to (16 bytes)
  final Uint8List archiveId;

  /// Total number of chunks in the archive
  final int totalChunks;

  /// Index of this chunk (0-based)
  final int chunkIndex;

  /// Payload data
  final Uint8List payload;

  /// CRC32 checksum of the payload
  final int crc32;

  /// Flags (compression, encryption)
  final int flags;

  /// Whether this chunk's data is compressed
  bool get isCompressed => NfarFlags.isCompressed(flags);

  /// Whether this chunk's data is encrypted
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

  /// Total size of this chunk when serialized
  int get totalSize => NfarHeaderSize.total + payload.length;

  /// Serialize this chunk to bytes.
  Uint8List toBytes() {
    final writer = BinaryWriter(NfarHeaderSize.total + payload.length);

    // Magic
    writer.writeBytes(Uint8List.fromList(nfarMagic));

    // Version
    writer.writeUint8(nfarVersion);

    // Flags
    writer.writeUint8(flags);

    // Archive ID
    writer.writeBytes(archiveId);

    // Total chunks
    writer.writeUint16(totalChunks);

    // Chunk index
    writer.writeUint16(chunkIndex);

    // Payload size
    writer.writeUint16(payload.length);

    // Payload
    writer.writeBytes(payload);

    // CRC32
    writer.writeUint32(crc32);

    return writer.toBytes();
  }

  /// Parse a chunk from bytes.
  ///
  /// Throws [FormatException] if the data is invalid.
  factory Chunk.fromBytes(Uint8List data) {
    if (data.length < NfarHeaderSize.total) {
      throw FormatException(
        'Data too short: expected at least ${NfarHeaderSize.total} bytes, '
        'got ${data.length}',
      );
    }

    final reader = BinaryReader(data);

    // Validate magic
    final magic = reader.readBytes(NfarHeaderSize.magic);
    if (!validateMagic(magic)) {
      throw const FormatException('Invalid magic bytes: not an NFAR chunk');
    }

    // Version
    final version = reader.readUint8();
    if (!validateVersion(version)) {
      throw FormatException(
        'Unsupported version: $version (expected $nfarVersion)',
      );
    }

    // Flags
    final flags = reader.readUint8();

    // Archive ID
    final archiveId = reader.readBytes(NfarHeaderSize.archiveId);

    // Total chunks
    final totalChunks = reader.readUint16();

    // Chunk index
    final chunkIndex = reader.readUint16();

    // Payload size
    final payloadSize = reader.readUint16();

    // Validate remaining data
    final expectedTotal = NfarHeaderOffset.payload + payloadSize + NfarHeaderSize.crc32;
    if (data.length < expectedTotal) {
      throw FormatException(
        'Data too short for payload: expected $expectedTotal bytes, '
        'got ${data.length}',
      );
    }

    // Payload
    final payload = reader.readBytes(payloadSize);

    // CRC32
    final crc32 = reader.readUint32();

    return Chunk(
      archiveId: archiveId,
      totalChunks: totalChunks,
      chunkIndex: chunkIndex,
      payload: payload,
      crc32: crc32,
      flags: flags,
    );
  }

  /// Create a copy with updated fields.
  Chunk copyWith({
    Uint8List? archiveId,
    int? totalChunks,
    int? chunkIndex,
    Uint8List? payload,
    int? crc32,
    int? flags,
  }) {
    return Chunk(
      archiveId: archiveId ?? this.archiveId,
      totalChunks: totalChunks ?? this.totalChunks,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      payload: payload ?? this.payload,
      crc32: crc32 ?? this.crc32,
      flags: flags ?? this.flags,
    );
  }

  @override
  List<Object?> get props => [
        archiveId,
        totalChunks,
        chunkIndex,
        payload,
        crc32,
        flags,
      ];

  @override
  String toString() =>
      'Chunk($chunkIndex/$totalChunks, ${payload.length} bytes, '
      'archive: ${archiveIdString.substring(0, 8)}...)';
}
