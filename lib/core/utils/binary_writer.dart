import 'dart:typed_data';

/// Utility class for writing binary data in big-endian format.
///
/// All multi-byte values are written in network byte order (big-endian)
/// for cross-platform compatibility.
class BinaryWriter {
  /// Creates a writer with a fixed buffer size.
  BinaryWriter(int size)
      : _buffer = Uint8List(size),
        _offset = 0;

  /// Creates a writer with an expandable buffer.
  BinaryWriter.expandable([int initialCapacity = 256])
      : _buffer = Uint8List(initialCapacity),
        _offset = 0,
        _expandable = true;

  Uint8List _buffer;
  int _offset;
  bool _expandable = false;

  /// Current write position.
  int get offset => _offset;

  /// Total buffer capacity.
  int get capacity => _buffer.length;

  /// Remaining space in buffer.
  int get remaining => _buffer.length - _offset;

  /// Ensure the buffer can fit [additionalBytes] more bytes.
  void _ensureCapacity(int additionalBytes) {
    final needed = _offset + additionalBytes;
    if (needed <= _buffer.length) return;

    if (!_expandable) {
      throw RangeError(
        'Buffer overflow: need $needed bytes, have ${_buffer.length}',
      );
    }

    // Double buffer size until it fits
    var newSize = _buffer.length;
    while (newSize < needed) {
      newSize *= 2;
    }

    final newBuffer = Uint8List(newSize);
    newBuffer.setRange(0, _offset, _buffer);
    _buffer = newBuffer;
  }

  /// Write a single byte (uint8).
  void writeUint8(int value) {
    _ensureCapacity(1);
    _buffer[_offset++] = value & 0xFF;
  }

  /// Write a 16-bit unsigned integer (big-endian).
  void writeUint16(int value) {
    _ensureCapacity(2);
    _buffer[_offset++] = (value >> 8) & 0xFF;
    _buffer[_offset++] = value & 0xFF;
  }

  /// Write a 32-bit unsigned integer (big-endian).
  void writeUint32(int value) {
    _ensureCapacity(4);
    _buffer[_offset++] = (value >> 24) & 0xFF;
    _buffer[_offset++] = (value >> 16) & 0xFF;
    _buffer[_offset++] = (value >> 8) & 0xFF;
    _buffer[_offset++] = value & 0xFF;
  }

  /// Write a 64-bit unsigned integer (big-endian).
  void writeUint64(int value) {
    _ensureCapacity(8);
    _buffer[_offset++] = (value >> 56) & 0xFF;
    _buffer[_offset++] = (value >> 48) & 0xFF;
    _buffer[_offset++] = (value >> 40) & 0xFF;
    _buffer[_offset++] = (value >> 32) & 0xFF;
    _buffer[_offset++] = (value >> 24) & 0xFF;
    _buffer[_offset++] = (value >> 16) & 0xFF;
    _buffer[_offset++] = (value >> 8) & 0xFF;
    _buffer[_offset++] = value & 0xFF;
  }

  /// Write raw bytes.
  void writeBytes(Uint8List bytes) {
    _ensureCapacity(bytes.length);
    _buffer.setRange(_offset, _offset + bytes.length, bytes);
    _offset += bytes.length;
  }

  /// Write a list of bytes.
  void writeByteList(List<int> bytes) {
    _ensureCapacity(bytes.length);
    for (final b in bytes) {
      _buffer[_offset++] = b & 0xFF;
    }
  }

  /// Write zeros for padding.
  void writePadding(int count) {
    _ensureCapacity(count);
    for (int i = 0; i < count; i++) {
      _buffer[_offset++] = 0;
    }
  }

  /// Get the written data as a Uint8List.
  ///
  /// Returns a view of the internal buffer up to the current offset.
  Uint8List toBytes() {
    return Uint8List.sublistView(_buffer, 0, _offset);
  }

  /// Reset the writer to the beginning.
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
}
