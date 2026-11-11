import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/photo/domain/jpeg_metadata.dart';

List<int> _seg(int marker, List<int> body) =>
    [0xFF, marker, (body.length + 2) >> 8, (body.length + 2) & 0xFF, ...body];

void main() {
  final soi = [0xFF, 0xD8];
  final app0 = _seg(0xE0, [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  final app1 = _seg(0xE1, [...ascii.encode('Exif'), 0, 0, ...ascii.encode('GPS')]);
  final com = _seg(0xFE, ascii.encode('hello'));
  final dqt = _seg(0xDB, List.filled(65, 3));
  final sof = _seg(0xC0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
  final dht = _seg(0xC4, List.filled(20, 1));
  final sos = _seg(0xDA, [1, 1, 0, 0, 0x3F, 0]);
  // Entropy data containing a stuffed FF00 and an RST marker.
  final data = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56];
  final eoi = [0xFF, 0xD9];

  test('strips APP1 and COM, keeps the rest byte-identical', () {
    final input = Uint8List.fromList(
        [...soi, ...app0, ...app1, ...com, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]);
    final out = stripJpegMetadata(input);
    expect(out,
        Uint8List.fromList([...soi, ...app0, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]));
    expect(latin1.decode(out).contains('Exif'), isFalse);
  });

  test('JPEG without metadata is unchanged', () {
    final input = Uint8List.fromList(
        [...soi, ...app0, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]);
    expect(stripJpegMetadata(input), input);
  });

  test('PNG throws FormatException', () {
    final png = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
    expect(() => stripJpegMetadata(png), throwsFormatException);
  });

  test('drops everything after the first EOI, appended gain map included', () {
    final xmp = _seg(0xE1, ascii.encode('http://ns.adobe.com/xap/1.0/\x00GainMap'));
    final gainMap = [...soi, ...app1, ...xmp, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi];
    final input = Uint8List.fromList(
        [...soi, ...app0, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi, ...gainMap, 0x00, 0x42]);
    final out = stripJpegMetadata(input);
    expect(out,
        Uint8List.fromList([...soi, ...app0, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]));
    expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
    expect(latin1.decode(out).contains('Exif'), isFalse);
    expect(latin1.decode(out).contains('GainMap'), isFalse);
  });

  test('progressive layout (several scans with tables between) is kept intact', () {
    final sof2 = _seg(0xC2, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
    final dht2 = _seg(0xC4, List.filled(18, 2));
    final data2 = [0x77, 0xFF, 0x00, 0xFF, 0xD3, 0x88];
    final input = Uint8List.fromList([
      ...soi, ...app0, ...app1, ...dqt, ...sof2, ...dht, ...sos, ...data,
      ...dht2, ...sos, ...data2, ...eoi,
    ]);
    expect(
        stripJpegMetadata(input),
        Uint8List.fromList([
          ...soi, ...app0, ...dqt, ...sof2, ...dht, ...sos, ...data,
          ...dht2, ...sos, ...data2, ...eoi,
        ]));
  });
}
