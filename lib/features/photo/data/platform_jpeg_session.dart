import 'package:flutter/services.dart';

import '../domain/jpeg_metadata.dart';
import '../domain/photo_fit.dart';

/// Native JPEG encoder (ImageIO on iOS, ImageDecoder/BitmapFactory on
/// Android). The native side decodes the source once per session and caches
/// the scaled bitmap per maxSide, so repeated encodes stay cheap.
const photoChannel = MethodChannel('com.nfcarchiver/photo');

/// The platform could not decode the chosen file as an image.
class PhotoDecodeException implements Exception {
  const PhotoDecodeException();

  @override
  String toString() => 'PhotoDecodeException';
}

class PlatformJpegSession implements JpegEncoderSession {
  final int _id;
  @override
  final int width;
  @override
  final int height;

  PlatformJpegSession._(this._id, this.width, this.height);

  /// Opens [path] natively. [width]/[height] are after EXIF orientation.
  /// Throws [PhotoDecodeException] when the file is not a decodable image.
  static Future<PlatformJpegSession> open(String path) async {
    try {
      final r = await photoChannel
          .invokeMapMethod<String, Object?>('open', {'path': path});
      return PlatformJpegSession._(
          r!['id'] as int, r['width'] as int, r['height'] as int);
    } on PlatformException catch (e) {
      if (e.code == 'decode_failed') throw const PhotoDecodeException();
      rethrow;
    }
  }

  @override
  Future<Uint8List> encode({required int maxSide, required int quality}) async {
    final bytes = await photoChannel.invokeMethod<Uint8List>(
        'encode', {'id': _id, 'maxSide': maxSide, 'quality': quality});
    // Belt and braces: the native encoders write no metadata, but whatever
    // they emit must never carry EXIF/XMP/GPS onto a tag.
    return stripJpegMetadata(bytes!);
  }

  @override
  Future<void> close() => photoChannel.invokeMethod<void>('close', {'id': _id});
}
