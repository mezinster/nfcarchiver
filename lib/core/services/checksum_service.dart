import 'dart:typed_data';

/// Service for calculating CRC32 checksums.
///
/// Uses the standard CRC-32 polynomial (IEEE 802.3):
/// x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1
class ChecksumService {
  /// Singleton instance
  static final ChecksumService instance = ChecksumService._();

  ChecksumService._();

  /// CRC32 lookup table (lazily initialized)
  late final List<int> _table = _generateTable();

  /// Polynomial for CRC-32 (IEEE 802.3)
  static const int _polynomial = 0xEDB88320;

  /// Generate the CRC32 lookup table
  List<int> _generateTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ _polynomial;
        } else {
          crc >>= 1;
        }
      }
      table[i] = crc;
    }
    return table;
  }

  /// Calculate CRC32 for the given data.
  ///
  /// Returns a 32-bit unsigned integer checksum.
  int calculate(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// Calculate CRC32 for a list of bytes.
  int calculateFromList(List<int> data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// Verify that data matches the expected CRC32.
  bool verify(Uint8List data, int expectedCrc) {
    return calculate(data) == expectedCrc;
  }

  /// Calculate CRC32 incrementally.
  ///
  /// Returns an [IncrementalCrc32] that can be updated with more data.
  IncrementalCrc32 createIncremental() {
    return IncrementalCrc32._(_table);
  }
}

/// Incremental CRC32 calculator.
///
/// Allows calculating CRC32 over multiple chunks of data.
class IncrementalCrc32 {
  IncrementalCrc32._(this._table) : _crc = 0xFFFFFFFF;

  final List<int> _table;
  int _crc;

  /// Update the CRC with more data.
  void update(Uint8List data) {
    for (final byte in data) {
      _crc = _table[(_crc ^ byte) & 0xFF] ^ (_crc >> 8);
    }
  }

  /// Update the CRC with a list of bytes.
  void updateFromList(List<int> data) {
    for (final byte in data) {
      _crc = _table[(_crc ^ byte) & 0xFF] ^ (_crc >> 8);
    }
  }

  /// Get the final CRC32 value.
  int finalize() {
    return _crc ^ 0xFFFFFFFF;
  }

  /// Reset the calculator to initial state.
  void reset() {
    _crc = 0xFFFFFFFF;
  }
}

/// Extension for convenience
extension Crc32Extension on Uint8List {
  /// Calculate CRC32 checksum for this data.
  int get crc32 => ChecksumService.instance.calculate(this);

  /// Verify this data against expected CRC32.
  bool verifyCrc32(int expectedCrc) =>
      ChecksumService.instance.verify(this, expectedCrc);
}
