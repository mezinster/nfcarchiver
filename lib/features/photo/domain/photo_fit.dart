import 'dart:typed_data';

/// Longest-side presets in pixels. "Original" is added by [candidateSides].
const List<int> photoPresets = [
  320, 480, 640, 800, 1024, 1280, 1440, 1600, 1920, 2560, 3840,
];

const int _qualityHigh = 95;
const int _qualityGood = 50;
const int _qualityFloor = 30;

/// A decoded image that can be re-encoded at different sizes and qualities.
abstract interface class JpegEncoderSession {
  int get width;
  int get height;
  Future<Uint8List> encode({required int maxSide, required int quality});
  Future<void> close();
}

/// Descending list of longest sides to try: the original first, then every
/// preset strictly smaller. Never upscales.
List<int> candidateSides(int longestSide) => [
      longestSide,
      ...photoPresets.reversed.where((p) => p < longestSide),
    ];

class PhotoFitResult {
  final int maxSide;
  final int quality;
  final Uint8List bytes;
  final bool fits;

  const PhotoFitResult({
    required this.maxSide,
    required this.quality,
    required this.bytes,
    required this.fits,
  });
}

/// Deterministic auto-fit: the largest side reaching quality >= 50, else the
/// largest side fitting at quality >= 30, else the smallest result, unfit.
Future<PhotoFitResult> fitToBudget(JpegEncoderSession s, int budgetBytes) async {
  final sides = candidateSides(s.width > s.height ? s.width : s.height);

  Future<PhotoFitResult> encodeAt(int side, int q) async {
    final bytes = await s.encode(maxSide: side, quality: q);
    return PhotoFitResult(
      maxSide: side,
      quality: q,
      bytes: bytes,
      fits: bytes.length <= budgetBytes,
    );
  }

  // Binary search for the highest quality in [lo, hi] that fits, given that
  // [known] (at lo) already fits.
  Future<PhotoFitResult> best(int side, int lo, int hi, PhotoFitResult known) async {
    var found = known;
    var a = lo + 1;
    var b = hi;
    while (a <= b) {
      final mid = (a + b) ~/ 2;
      final r = await encodeAt(side, mid);
      if (r.fits) {
        found = r;
        a = mid + 1;
      } else {
        b = mid - 1;
      }
    }
    return found;
  }

  if (budgetBytes <= 0) {
    return encodeAt(sides.last, _qualityFloor);
  }

  for (final side in sides) {
    final r = await encodeAt(side, _qualityGood);
    if (r.fits) return best(side, _qualityGood, _qualityHigh, r);
  }
  PhotoFitResult? last;
  for (final side in sides) {
    final r = await encodeAt(side, _qualityFloor);
    last = r;
    if (r.fits) return best(side, _qualityFloor, _qualityGood - 1, r);
  }
  return last!;
}

/// One encode at the user's chosen settings.
Future<PhotoFitResult> encodeManual(
  JpegEncoderSession s, {
  required int maxSide,
  required int quality,
  required int budgetBytes,
}) async {
  final bytes = await s.encode(maxSide: maxSide, quality: quality);
  return PhotoFitResult(
    maxSide: maxSide,
    quality: quality,
    bytes: bytes,
    fits: bytes.length <= budgetBytes,
  );
}
