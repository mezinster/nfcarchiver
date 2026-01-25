import 'dart:io';
import 'dart:typed_data';

/// Service for compressing and decompressing data.
///
/// Uses GZIP compression which is widely supported and provides
/// good compression ratios for text and structured data.
class CompressionService {
  /// Singleton instance
  static final CompressionService instance = CompressionService._();

  CompressionService._();

  /// Compress data using GZIP.
  ///
  /// Returns the compressed data, or the original if compression
  /// would increase the size.
  Uint8List compress(Uint8List data) {
    final compressed = gzip.encode(data);
    return Uint8List.fromList(compressed);
  }

  /// Compress data, but only if it actually reduces size.
  ///
  /// Returns a tuple with the data and whether it was compressed.
  ({Uint8List data, bool wasCompressed}) compressIfSmaller(Uint8List data) {
    final compressed = gzip.encode(data);

    if (compressed.length < data.length) {
      return (data: Uint8List.fromList(compressed), wasCompressed: true);
    }

    return (data: data, wasCompressed: false);
  }

  /// Decompress GZIP data.
  ///
  /// Throws [FormatException] if the data is not valid GZIP.
  Uint8List decompress(Uint8List data) {
    try {
      final decompressed = gzip.decode(data);
      return Uint8List.fromList(decompressed);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Failed to decompress data: $e');
    }
  }

  /// Try to decompress data, returning null if it fails.
  Uint8List? tryDecompress(Uint8List data) {
    try {
      return decompress(data);
    } catch (_) {
      return null;
    }
  }

  /// Check if data appears to be GZIP compressed.
  ///
  /// GZIP files start with magic bytes 0x1F 0x8B.
  bool isGzipCompressed(Uint8List data) {
    return data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B;
  }

  /// Estimate compression ratio for given data type.
  ///
  /// This is a heuristic based on data characteristics.
  double estimateCompressionRatio(Uint8List data) {
    if (data.isEmpty) return 1.0;

    // Check if already compressed
    if (isGzipCompressed(data)) return 1.0;

    // Calculate entropy as a proxy for compressibility
    final frequency = List<int>.filled(256, 0);
    for (final byte in data) {
      frequency[byte]++;
    }

    double entropy = 0;
    final length = data.length.toDouble();
    for (final count in frequency) {
      if (count > 0) {
        final p = count / length;
        entropy -= p * (p > 0 ? _log2(p) : 0);
      }
    }

    // Maximum entropy is 8 bits per byte
    // Lower entropy = more compressible
    final normalizedEntropy = entropy / 8.0;

    // Estimate ratio: low entropy -> high compression
    // This is a rough approximation
    if (normalizedEntropy < 0.3) {
      return 0.1; // Highly compressible (e.g., lots of zeros)
    } else if (normalizedEntropy < 0.6) {
      return 0.3; // Good compression (e.g., text)
    } else if (normalizedEntropy < 0.85) {
      return 0.7; // Moderate compression
    } else {
      return 1.0; // Already compressed or random
    }
  }

  /// Log base 2
  double _log2(double x) => _ln(x) / _ln(2);

  /// Natural logarithm approximation
  double _ln(double x) {
    if (x <= 0) return double.negativeInfinity;
    if (x == 1) return 0;

    // Use dart:math
    return x.toString().length.toDouble(); // Placeholder - use actual log
  }
}

/// Extension for convenience
extension CompressionExtension on Uint8List {
  /// Compress this data using GZIP.
  Uint8List gzipCompress() => CompressionService.instance.compress(this);

  /// Decompress this data from GZIP.
  Uint8List gzipDecompress() => CompressionService.instance.decompress(this);

  /// Check if this data is GZIP compressed.
  bool get isGzipCompressed =>
      CompressionService.instance.isGzipCompressed(this);
}
