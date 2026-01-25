/// NFAR (NFC Archive) format constants and specifications.
///
/// Format version 1 structure:
/// ```
/// ┌─────────────────────────────────────────────────────┐
/// │ Magic (4 bytes): "NFAR" = 0x4E464152               │
/// ├─────────────────────────────────────────────────────┤
/// │ Version (1 byte): 0x01                              │
/// ├─────────────────────────────────────────────────────┤
/// │ Flags (1 byte):                                     │
/// │   bit 0: compressed (0=none, 1=gzip)                │
/// │   bit 1: encrypted (0=no, 1=AES-256-GCM)            │
/// │   bits 2-7: reserved                                │
/// ├─────────────────────────────────────────────────────┤
/// │ Archive ID (16 bytes): UUID v4                      │
/// ├─────────────────────────────────────────────────────┤
/// │ Total Chunks (2 bytes): uint16 big-endian           │
/// ├─────────────────────────────────────────────────────┤
/// │ Chunk Index (2 bytes): uint16 big-endian (0-based)  │
/// ├─────────────────────────────────────────────────────┤
/// │ Payload Size (2 bytes): uint16 big-endian           │
/// ├─────────────────────────────────────────────────────┤
/// │ Payload (N bytes): data                             │
/// ├─────────────────────────────────────────────────────┤
/// │ CRC32 (4 bytes): checksum of payload                │
/// └─────────────────────────────────────────────────────┘
/// ```
library;

import 'dart:typed_data';

/// Magic bytes identifying NFAR format: "NFAR" in ASCII
const List<int> nfarMagic = [0x4E, 0x46, 0x41, 0x52]; // N, F, A, R

/// Current format version
const int nfarVersion = 0x01;

/// Header field sizes in bytes
abstract class NfarHeaderSize {
  static const int magic = 4;
  static const int version = 1;
  static const int flags = 1;
  static const int archiveId = 16;
  static const int totalChunks = 2;
  static const int chunkIndex = 2;
  static const int payloadSize = 2;
  static const int crc32 = 4;

  /// Total header size (without payload)
  static const int total = magic +
      version +
      flags +
      archiveId +
      totalChunks +
      chunkIndex +
      payloadSize +
      crc32;
}

/// Header field offsets
abstract class NfarHeaderOffset {
  static const int magic = 0;
  static const int version = 4;
  static const int flags = 5;
  static const int archiveId = 6;
  static const int totalChunks = 22;
  static const int chunkIndex = 24;
  static const int payloadSize = 26;
  static const int payload = 28;
}

/// Flag bit positions
abstract class NfarFlags {
  /// Bit 0: compression enabled (GZIP)
  static const int compressed = 0x01;

  /// Bit 1: encryption enabled (AES-256-GCM)
  static const int encrypted = 0x02;

  /// Check if compression flag is set
  static bool isCompressed(int flags) => (flags & compressed) != 0;

  /// Check if encryption flag is set
  static bool isEncrypted(int flags) => (flags & encrypted) != 0;

  /// Create flags byte from options
  static int create({bool compress = false, bool encrypt = false}) {
    int flags = 0;
    if (compress) flags |= compressed;
    if (encrypt) flags |= encrypted;
    return flags;
  }
}

/// NFC tag type specifications
enum NfcTagType {
  /// NTAG213: 144 bytes user memory
  ntag213(name: 'NTAG213', capacity: 144),

  /// NTAG215: 504 bytes user memory
  ntag215(name: 'NTAG215', capacity: 504),

  /// NTAG216: 888 bytes user memory
  ntag216(name: 'NTAG216', capacity: 888),

  /// MIFARE Ultralight: 48 bytes user memory
  mifareUltralight(name: 'MIFARE Ultralight', capacity: 48),

  /// MIFARE Ultralight C: 144 bytes user memory
  mifareUltralightC(name: 'MIFARE Ultralight C', capacity: 144),

  /// Generic 1KB tag
  generic1k(name: 'Generic 1KB', capacity: 1024),

  /// Custom capacity (user-defined)
  custom(name: 'Custom', capacity: 0);

  const NfcTagType({required this.name, required this.capacity});

  final String name;
  final int capacity;

  /// Maximum payload size for this tag type
  int get maxPayloadSize {
    // NDEF overhead includes:
    // - NDEF record header: 3-6 bytes (flags, type length, payload length)
    // - MIME type: 33 bytes ("application/vnd.nfcarchiver.chunk")
    // - NDEF TLV wrapper: ~5 bytes
    // Total NDEF overhead: ~41-44 bytes
    // We use 44 bytes as a safe margin
    const ndefOverhead = 44;
    final available = capacity - ndefOverhead;
    return available - NfarHeaderSize.total;
  }

  /// Calculate max payload for a specific detected NDEF capacity.
  /// Use this when you know the actual available space from ndef.maxSize.
  static int maxPayloadForCapacity(int ndefCapacity) {
    // NDEF record overhead for MIME type record
    const mimeTypeLength = 33; // "application/vnd.nfcarchiver.chunk"
    // Use long format (4-byte length) for safety
    const ndefRecordOverhead = 6 + mimeTypeLength; // 39 bytes

    // NFAR format overhead
    const nfarOverhead = NfarHeaderSize.total; // 32 bytes (28 header + 4 CRC)

    final payload = ndefCapacity - ndefRecordOverhead - nfarOverhead;
    return payload > 0 ? payload : 0;
  }

  /// Check if a payload of given size fits in this tag
  bool canFitPayload(int payloadSize) => payloadSize <= maxPayloadSize;

  /// Calculate number of chunks needed for data of given size
  int chunksNeeded(int dataSize) {
    if (maxPayloadSize <= 0) return 0;
    return (dataSize + maxPayloadSize - 1) ~/ maxPayloadSize;
  }
}

/// Maximum values
abstract class NfarLimits {
  /// Maximum number of chunks (uint16 max)
  static const int maxChunks = 65535;

  /// Maximum payload size per chunk (uint16 max)
  static const int maxPayloadSize = 65535;

  /// Minimum supported tag capacity
  static const int minTagCapacity = 64;
}

/// NDEF MIME type for NFAR chunks
const String nfarMimeType = 'application/vnd.nfcarchiver.chunk';

/// Validates magic bytes
bool validateMagic(Uint8List data) {
  if (data.length < NfarHeaderSize.magic) return false;
  for (int i = 0; i < nfarMagic.length; i++) {
    if (data[i] != nfarMagic[i]) return false;
  }
  return true;
}

/// Validates format version
bool validateVersion(int version) => version == nfarVersion;
