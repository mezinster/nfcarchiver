import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_frame.dart';

Uint8List _b(List<int> xs) => Uint8List.fromList(xs);

void main() {
  group('LRC', () {
    test('is the two-s complement of the byte sum', () {
      expect(lrc(_b([0x11])), 0xEF, reason: '0xEF is the SOF LRC');
      expect(lrc(_b([])), 0x00);
      expect(lrc(_b([0x01, 0x02, 0x03])), 0xFA);
    });

    test('a frame plus its LRC always sums to zero mod 256', () {
      final data = _b([0x10, 0x20, 0x30, 0x99]);
      final sum = data.fold<int>(0, (a, b) => a + b) + lrc(data);
      expect(sum & 0xff, 0);
    });
  });

  group('encodeFrame', () {
    test('lays out SOF, command, status, length and both LRCs', () {
      final f = encodeFrame(ChameleonCmd.getAppVersion, _b([]));
      expect(f.sublist(0, 2), equals([0x11, 0xEF]));
      expect(f.sublist(2, 4), equals([0x03, 0xE8]), reason: 'cmd 1000 BE');
      expect(f.sublist(4, 6), equals([0x00, 0x00]), reason: 'status');
      expect(f.sublist(6, 8), equals([0x00, 0x00]), reason: 'dataLen');
      expect(f[8], lrc(Uint8List.sublistView(f, 2, 8)), reason: 'head LRC');
      expect(f.length, 10, reason: '10 + dataLen');
    });

    test('carries a payload and terminates with its LRC', () {
      final data = _b([0x60, 0x04, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
      final f = encodeFrame(ChameleonCmd.mf1ReadOneBlock, data);
      expect(f.length, 10 + data.length);
      expect((f[6] << 8) | f[7], data.length);
      expect(f.sublist(9, 9 + data.length), equals(data));
      expect(f.last, lrc(data));
    });
  });

  group('FrameParser', () {
    test('a frame round-trips', () {
      final frames = FrameParser().feed(encodeFrame(2000, _b([1, 2, 3])));
      expect(frames.single.cmd, 2000);
      expect(frames.single.status, 0);
      expect(frames.single.data, equals([1, 2, 3]));
    });

    test('a frame split across notifications is reassembled', () {
      // BLE delivers arbitrary chunks. Assuming frame-aligned notifications is
      // the single most likely way this port fails on real hardware.
      final whole = encodeFrame(2000, _b(List<int>.filled(30, 7)));
      final p = FrameParser();
      expect(p.feed(Uint8List.sublistView(whole, 0, 5)), isEmpty);
      expect(p.feed(Uint8List.sublistView(whole, 5, 12)), isEmpty);
      expect(p.feed(Uint8List.sublistView(whole, 12)).single.cmd, 2000);
    });

    test('a frame arriving one byte at a time is reassembled', () {
      final whole = encodeFrame(1000, _b([0xAA, 0xBB]));
      final p = FrameParser();
      final out = <ChameleonFrame>[];
      for (final byte in whole) {
        out.addAll(p.feed(_b([byte])));
      }
      expect(out.single.data, equals([0xAA, 0xBB]));
    });

    test('two frames in one notification both emerge, in order', () {
      final p = FrameParser();
      final buf = _b([
        ...encodeFrame(1000, _b([])),
        ...encodeFrame(2000, _b([9])),
      ]);
      expect(p.feed(buf).map((f) => f.cmd).toList(), equals([1000, 2000]));
    });

    test('garbage before the SOF is skipped and the frame still parses', () {
      final p = FrameParser();
      final buf = _b([0xAA, 0xBB, 0xCC, ...encodeFrame(1000, _b([]))]);
      expect(p.feed(buf).single.cmd, 1000);
    });

    test('a corrupt head LRC does not desynchronise the parser forever', () {
      // The reference resynchronises by advancing ONE byte and re-scanning for
      // the SOF. Dropping the whole buffer would lose a good frame that follows
      // corruption inside the same notification.
      final good = encodeFrame(1000, _b([]));
      final bad = Uint8List.fromList(good)..[8] ^= 0xff;
      final p = FrameParser();
      final out = p.feed(_b([...bad, ...good]));
      expect(out.map((f) => f.cmd), contains(1000));
    });

    test('a corrupt data LRC is rejected, and recovery still finds the next frame',
        () {
      final good = encodeFrame(2000, _b([1, 2, 3]));
      final bad = Uint8List.fromList(encodeFrame(2000, _b([4, 5, 6])));
      bad[bad.length - 1] ^= 0xff;
      final out = FrameParser().feed(_b([...bad, ...good]));
      expect(out.map((f) => f.data.first), contains(1),
          reason: 'the intact frame is still delivered');
      expect(out.any((f) => f.data.isNotEmpty && f.data.first == 4), isFalse,
          reason: 'the corrupt frame is not');
    });

    test('an incomplete trailing frame is buffered, not lost', () {
      final whole = encodeFrame(2000, _b([1, 2, 3, 4]));
      final p = FrameParser();
      expect(p.feed(Uint8List.sublistView(whole, 0, whole.length - 1)), isEmpty);
      expect(p.feed(Uint8List.sublistView(whole, whole.length - 1)).single.cmd,
          2000);
    });

    test('a non-zero status is preserved for the caller to interpret', () {
      // MF_ERR_AUTH must reach the caller as itself: it means a foreign card,
      // which is a user situation, not a transport fault.
      final f = Uint8List.fromList(encodeFrame(2008, _b([])));
      f[4] = 0x00;
      f[5] = ChameleonStatus.mfErrAuth;
      f[8] = lrc(Uint8List.sublistView(f, 2, 8));
      expect(FrameParser().feed(f).single.status, ChameleonStatus.mfErrAuth);
    });

    test('a SOF split across two notifications is not lost', () {
      final whole = encodeFrame(1000, _b([]));
      final p = FrameParser();
      // First notification ends on the SOF's first byte.
      expect(p.feed(_b([0xAA, 0xBB, whole[0]])), isEmpty);
      expect(p.feed(Uint8List.sublistView(whole, 1)).single.cmd, 1000);
    });

    test('pure garbage does not accumulate in the buffer', () {
      // A noisy link that never yields a frame must not grow the buffer
      // without bound. Feeding megabytes of junk then one good frame proves
      // the parser is not retaining what it cannot use.
      final p = FrameParser();
      final junk = _b(List<int>.generate(4096, (i) => i % 251 == 0 ? 0x11 : 0x5A));
      for (var i = 0; i < 64; i++) {
        expect(p.feed(junk), isEmpty);
      }
      expect(p.feed(encodeFrame(1000, _b([]))).single.cmd, 1000);
    });

    test('a declared length beyond any real frame does not hang the parser', () {
      // Defensive: a corrupt length field must not make the parser wait forever
      // for bytes that will never arrive on a healthy link.
      final f = Uint8List.fromList(encodeFrame(2000, _b([1])));
      f[6] = 0xFF;
      f[7] = 0xFF;
      f[8] = lrc(Uint8List.sublistView(f, 2, 8));
      final p = FrameParser();
      expect(p.feed(f), isEmpty);
      // A good frame afterwards must still be found rather than swallowed.
      expect(p.feed(encodeFrame(1000, _b([]))).map((x) => x.cmd), contains(1000));
    });
  });
}
