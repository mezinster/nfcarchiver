import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';

/// Formats NFAR chunks for NDEF storage and parses NDEF records back to chunks.
class NdefFormatter {
  /// Singleton instance
  static final NdefFormatter instance = NdefFormatter._();

  NdefFormatter._();

  /// Convert a Chunk to an NDEF message.
  NdefMessage chunkToNdef(Chunk chunk) {
    final bytes = chunk.toBytes();

    // Create NDEF record with custom MIME type
    final record = NdefRecord.createMime(
      nfarMimeType,
      bytes,
    );

    return NdefMessage([record]);
  }

  /// Convert NDEF message to a Chunk.
  ///
  /// Returns null if the message doesn't contain a valid NFAR chunk.
  Chunk? ndefToChunk(NdefMessage message) {
    for (final record in message.records) {
      // Check for our MIME type
      if (_isNfarRecord(record)) {
        try {
          return Chunk.fromBytes(Uint8List.fromList(record.payload));
        } catch (_) {
          // Invalid chunk data
          continue;
        }
      }

      // Also try to parse as raw binary (for backwards compatibility)
      if (record.typeNameFormat == NdefTypeNameFormat.unknown ||
          record.typeNameFormat == NdefTypeNameFormat.media) {
        try {
          final data = Uint8List.fromList(record.payload);
          if (validateMagic(data)) {
            return Chunk.fromBytes(data);
          }
        } catch (_) {
          continue;
        }
      }
    }

    return null;
  }

  /// Check if an NDEF record is an NFAR chunk.
  bool _isNfarRecord(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.media) {
      return false;
    }

    final type = String.fromCharCodes(record.type);
    return type == nfarMimeType;
  }

  /// Check if NDEF message contains an NFAR chunk.
  bool containsNfarChunk(NdefMessage message) {
    for (final record in message.records) {
      if (_isNfarRecord(record)) return true;

      // Check for magic bytes in payload
      if (record.payload.length >= NfarHeaderSize.magic) {
        if (validateMagic(Uint8List.fromList(record.payload))) {
          return true;
        }
      }
    }
    return false;
  }

  /// Get the required NDEF message size for a chunk.
  int requiredNdefSize(Chunk chunk) {
    // NDEF record overhead:
    // - 1 byte: flags/type name format
    // - 1 byte: type length
    // - 1-4 bytes: payload length (depends on size)
    // - N bytes: type (MIME type string)
    // - M bytes: payload (chunk bytes)

    final payloadSize = chunk.totalSize;
    final typeSize = nfarMimeType.length;

    // Short record if payload < 256 bytes
    final lengthBytes = payloadSize < 256 ? 1 : 4;

    return 1 + 1 + lengthBytes + typeSize + payloadSize;
  }

  /// Create an empty NDEF message (for erasing tags).
  NdefMessage createEmpty() {
    return NdefMessage([
      NdefRecord.createText(''),
    ]);
  }

  /// Parse metadata from NDEF message without fully parsing the chunk.
  ///
  /// Returns (archiveId, chunkIndex, totalChunks) or null if invalid.
  ({String archiveId, int chunkIndex, int totalChunks})? parseMetadata(
    NdefMessage message,
  ) {
    for (final record in message.records) {
      final payload = record.payload;
      if (payload.length < NfarHeaderOffset.payload) continue;

      final data = Uint8List.fromList(payload);
      if (!validateMagic(data)) continue;

      try {
        // Extract just the metadata without full parsing
        final archiveIdBytes = data.sublist(
          NfarHeaderOffset.archiveId,
          NfarHeaderOffset.archiveId + NfarHeaderSize.archiveId,
        );

        final archiveId = _bytesToUuid(archiveIdBytes);

        final totalChunks = (data[NfarHeaderOffset.totalChunks] << 8) |
            data[NfarHeaderOffset.totalChunks + 1];

        final chunkIndex = (data[NfarHeaderOffset.chunkIndex] << 8) |
            data[NfarHeaderOffset.chunkIndex + 1];

        return (
          archiveId: archiveId,
          chunkIndex: chunkIndex,
          totalChunks: totalChunks,
        );
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  /// Convert bytes to UUID string.
  String _bytesToUuid(List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
