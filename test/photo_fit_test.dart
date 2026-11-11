import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/photo/domain/photo_fit.dart';

import 'support/fake_jpeg_session.dart';

int _model(int side, int q) => side * side * q ~/ 1000;

void main() {
  test('candidateSides', () {
    expect(candidateSides(4032),
        [4032, 3840, 2560, 1920, 1600, 1440, 1280, 1024, 800, 640, 480, 320]);
    expect(candidateSides(640), [640, 480, 320]);
    expect(candidateSides(200), [200]);
    expect(candidateSides(1024).where((s) => s == 1024).length, 1);
  });

  test('picks largest side reaching q50, then max quality', () async {
    final budget = _model(1024, 50) + 100; // 1280 at q50 is far larger
    final s = FakeJpegSession(3024, 4032, size: _model);
    final r = await fitToBudget(s, budget);
    expect(r.fits, isTrue);
    expect(r.maxSide, 1024);
    var expected = 50;
    for (var q = 50; q <= 95; q++) {
      if (_model(1024, q) <= budget) expected = q;
    }
    expect(r.quality, expected);
    expect(r.bytes.length, _model(1024, expected));
    expect(s.calls.length, lessThanOrEqualTo(candidateSides(4032).length + 7));
  });

  test('falls back to q30-49 when no side reaches q50', () async {
    // Steep: 320 px at q50 exceeds 480 px at q35, which is below 640 px at q30.
    int steep(int side, int q) => side * side * q * q * q ~/ 100000;
    final budget = steep(480, 35) + 10;
    final s = FakeJpegSession(3000, 4000, size: steep);
    final r = await fitToBudget(s, budget);
    expect(r.fits, isTrue);
    expect(r.maxSide, 480);
    var expected = 30;
    for (var q = 30; q <= 49; q++) {
      if (steep(480, q) <= budget) expected = q;
    }
    expect(r.quality, expected);
    expect(r.quality, inInclusiveRange(30, 49));
  });

  test('nothing fits', () async {
    final s = FakeJpegSession(3000, 4000, size: _model);
    final r = await fitToBudget(s, 10);
    expect(r.fits, isFalse);
    expect(r.maxSide, 320);
    expect(r.quality, 30);
  });

  test('budget <= 0 encodes at most once', () async {
    for (final b in [0, -50]) {
      final s = FakeJpegSession(3000, 4000, size: _model);
      final r = await fitToBudget(s, b);
      expect(r.fits, isFalse);
      expect(s.calls.length, lessThanOrEqualTo(1));
    }
  });

  test('small original is never upscaled', () async {
    final s = FakeJpegSession(200, 100, size: (side, q) => 5000);
    final r = await fitToBudget(s, 10);
    expect(r.maxSide, 200);
    expect(s.calls.every((c) => c.maxSide == 200), isTrue);
  });

  test('deterministic', () async {
    final a = FakeJpegSession(3024, 4032, size: _model);
    final b = FakeJpegSession(3024, 4032, size: _model);
    final ra = await fitToBudget(a, 200000);
    final rb = await fitToBudget(b, 200000);
    expect(a.calls, b.calls);
    expect((ra.maxSide, ra.quality, ra.fits), (rb.maxSide, rb.quality, rb.fits));
  });

  test('encodeManual encodes once and judges fit', () async {
    final s = FakeJpegSession(3000, 4000, size: _model);
    final r = await encodeManual(s,
        maxSide: 800, quality: 70, budgetBytes: _model(800, 70));
    expect(s.calls.length, 1);
    expect(r.fits, isTrue);
    final r2 = await encodeManual(s,
        maxSide: 800, quality: 70, budgetBytes: _model(800, 70) - 1);
    expect(r2.fits, isFalse);
  });
}
