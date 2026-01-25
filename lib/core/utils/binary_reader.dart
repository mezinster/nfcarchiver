import 'dart:typed_data';

/// Utility class for reading binary data in big-endian format.
///
/// All multi-byte values are read as network byte order (big-endian)
/// for cross-platform compatibility.
class BinaryReader {
  /// Creates a reader from a Uint8List.
  BinaryReader(this._buffer) : _offset = 0;

  /// Creates a reader from a List<int>.
  BinaryReader.fromList(List<int> bytes)
      : _buffer = bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        _offset = 0;

  final Uint8List _buffer;
  int _offset;

  /// Current read position.
  int get offset => _offset;

  /// Total buffer length.
  int get length => _buffer.length;

  /// Remaining bytes to read.
  int get remaining => _buffer.length - _offset;

  /// Whether there are more bytes to read.
  bool get hasRemaining => _offset < _buffer.length;

  /// Check if there are enough bytes remaining.
  void _checkRemaining(int count) {
    if (_offset + count > _buffer.length) {
      throw RangeError(
        'Buffer underflow: need $count bytes, have $remaining remaining',
      );
    }
  }

  /// Read a single byte (uint8).
  int readUint8() {
    _checkRemaining(1);
    return _buffer[_offset++];
  }

  /// Read a 16-bit unsigned integer (big-endian).
  int readUint16() {
    _checkRemaining(2);
    final value = (_buffer[_offset] << 8) | _buffer[_offset + 1];
    _offset += 2;
    return value;
  }

  /// Read a 32-bit unsigned integer (big-endian).
  int readUint32() {
    _checkRemaining(4);
    final value = (_buffer[_offset] << 24) |
        (_buffer[_offset + 1] << 16) |
        (_buffer[_offset + 2] << 8) |
        _buffer[_offset + 3];
    _offset += 4;
    return value;
  }

  /// Read a 64-bit unsigned integer (big-endian).
  int readUint64() {
    _checkRemaining(8);
    final high = readUint32();
    final low = readUint32();
    return (high << 32) | low;
  }

  /// Read [count] bytes and return as Uint8List.
  Uint8List readBytes(int count) {
    _checkRemaining(count);
    final bytes = Uint8List.sublistView(_buffer, _offset, _offset + count);
    _offset += count;
    return bytes;
  }

  /// Read remaining bytes.
  Uint8List readRemaining() {
    return readBytes(remaining);
  }

  /// Peek at the next byte without advancing the position.
  int peekUint8() {
    _checkRemaining(1);
    return _buffer[_offset];
  }

  /// Peek at the next [count] bytes without advancing the position.
  Uint8List peekBytes(int count) {
    _checkRemaining(count);
    return Uint8List.sublistView(_buffer, _offset, _offset + count);
  }

  /// Skip [count] bytes.
  void skip(int count) {
    _checkRemaining(count);
    _offset += count;
  }

  /// Reset the reader to the beginning.
  void reset() {
    _offset = 0;
  }

  /// Seek to a specific position.
  void seek(int position) {
    if (position < 0 || position > _buffer.length) {
      throw RangeError.range(position, 0, _buffer.length, 'position');
    }
    _offset = position;
  }

  /// Get a subview of the buffer from current position.
  Uint8List subview([int? length]) {
    final end = length != null ? _offset + length : _buffer.length;
    if (end > _buffer.length) {
      throw RangeError('Subview extends beyond buffer');
    }
    return Uint8List.sublistView(_buffer, _offset, end);
  }
}
