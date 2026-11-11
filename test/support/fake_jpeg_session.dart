import 'dart:typed_data';

import 'package:nfc_archiver/features/photo/domain/photo_fit.dart';

/// A [JpegEncoderSession] whose output length is computed by [size].
class FakeJpegSession implements JpegEncoderSession {
  FakeJpegSession(this.width, this.height, {required this.size});

  @override
  final int width;
  @override
  final int height;
  final int Function(int side, int quality) size;
  final List<({int maxSide, int quality})> calls = [];
  bool closed = false;

  @override
  Future<Uint8List> encode({required int maxSide, required int quality}) async {
    calls.add((maxSide: maxSide, quality: quality));
    return Uint8List(size(maxSide, quality));
  }

  @override
  Future<void> close() async => closed = true;
}
