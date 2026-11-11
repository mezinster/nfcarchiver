import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/photo/data/platform_jpeg_session.dart';

List<int> _seg(int marker, List<int> body) =>
    [0xFF, marker, (body.length + 2) >> 8, (body.length + 2) & 0xFF, ...body];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final soi = [0xFF, 0xD8];
  final app0 =
      _seg(0xE0, [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  final app1 = _seg(0xE1, [...ascii.encode('Exif'), 0, 0, ...ascii.encode('GPS')]);
  final dqt = _seg(0xDB, List.filled(65, 3));
  final sof = _seg(0xC0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
  final dht = _seg(0xC4, List.filled(20, 1));
  final sos = _seg(0xDA, [1, 1, 0, 0, 0x3F, 0]);
  final data = [0x12, 0xFF, 0x00, 0x34];
  final eoi = [0xFF, 0xD9];

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'open':
          return {'id': 7, 'width': 3024, 'height': 4032};
        case 'encode':
          return Uint8List.fromList(
              [...soi, ...app0, ...app1, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]);
        case 'close':
          return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(photoChannel, null));

  test('open reports the dimensions from the native side', () async {
    final s = await PlatformJpegSession.open('/x/photo.heic');
    expect(s.width, 3024);
    expect(s.height, 4032);
    expect(calls.single.method, 'open');
    expect(calls.single.arguments, {'path': '/x/photo.heic'});
  });

  test('encode strips APP1 from the native result', () async {
    final s = await PlatformJpegSession.open('/x/photo.jpg');
    final out = await s.encode(maxSide: 640, quality: 70);
    expect(calls.last.method, 'encode');
    expect(calls.last.arguments, {'id': 7, 'maxSide': 640, 'quality': 70});
    expect(out,
        Uint8List.fromList([...soi, ...app0, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi]));
    expect(latin1.decode(out).contains('Exif'), isFalse);
  });

  test('decode_failed maps to PhotoDecodeException', () async {
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      throw PlatformException(code: 'decode_failed');
    });
    expect(PlatformJpegSession.open('/x/broken.bin'),
        throwsA(isA<PhotoDecodeException>()));
  });

  test('close sends the session id', () async {
    final s = await PlatformJpegSession.open('/x/photo.jpg');
    await s.close();
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, {'id': 7});
  });
}
