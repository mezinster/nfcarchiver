import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';

void main() {
  group('layout constants', () {
    test('47 usable blocks, excluding block 0 and every sector trailer', () {
      expect(usableBlockIndexes.length, 47);
      expect(usableBlockIndexes.contains(0), isFalse);
      for (final b in usableBlockIndexes) {
        expect(b % 4 == 3, isFalse, reason: 'block $b is a sector trailer');
      }
      expect(usableBlockIndexes.first, 1);
      expect(usableBlockIndexes.last, 62);
    });

    test('capacity matches the web app', () {
      expect(cardCapacityBytes, 752);
      expect(cardPayloadSize, 720);
    });
  });

  group('chunkToBlocks', () {
    test('maps bytes onto usable blocks in order', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final writes = chunkToBlocks(bytes);
      expect(writes.length, 2);
      expect(writes[0].block, 1);
      expect(writes[1].block, 2);
      expect(writes[0].data, bytes.sublist(0, 16));
    });

    test('zero-pads the final partial block', () {
      final writes = chunkToBlocks(Uint8List.fromList([1, 2, 3]));
      expect(writes.length, 1);
      expect(writes[0].data.length, 16);
      expect(writes[0].data.sublist(3), Uint8List(13));
    });

    test('skips sector trailers once past block 2', () {
      final writes = chunkToBlocks(Uint8List(16 * 4));
      expect(writes.map((w) => w.block).toList(), [1, 2, 4, 5]);
    });

    test('rejects a chunk larger than the card', () {
      expect(() => chunkToBlocks(Uint8List(cardCapacityBytes + 1)),
          throwsA(isA<MifareCapacityException>()));
    });
  });

  group('probing', () {
    test('firstBlockIsNfar recognises magic + version', () {
      final block = Uint8List(16)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01]); // "NFAR" v1
      expect(firstBlockIsNfar(block), isTrue);
    });

    test('firstBlockIsNfar rejects a blank block', () {
      expect(firstBlockIsNfar(Uint8List(16)), isFalse);
    });

    test('nfarTotalLength reads the big-endian payload size at offset 26', () {
      final header = Uint8List(32)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01])
        ..[26] = 0x01
        ..[27] = 0x2C; // 300
      expect(nfarTotalLength(header), 332); // 32 overhead + 300
    });

    test('nfarTotalLength rejects a payload declaring over-capacity total', () {
      final header = Uint8List(32)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01])
        ..[26] = 0xFF
        ..[27] = 0xFF; // 65535 bytes payload -> 32 + 65535 = 65567 total
      expect(() => nfarTotalLength(header), throwsA(isA<FormatException>()));
    });

    test('nfarTotalLength accepts a payload landing exactly on capacity', () {
      final header = Uint8List(32)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01])
        ..[26] = 0x02
        ..[27] = 0xD0; // 720 bytes payload -> 32 + 720 = 752 (exact capacity)
      expect(nfarTotalLength(header), 752);
    });
  });

  group('4K geometry', () {
    Uint8List header(int payload) {
      final h = Uint8List(NfarHeaderSize.total);
      h.setAll(0, nfarMagic);
      h[nfarMagic.length] = nfarVersion;
      ByteData.sublistView(h).setUint16(26, payload);
      return h;
    }

    Uint8List bytesOf(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i & 0xff));

    test('constants', () {
      expect(usableBlockIndexes4k.length, 215);
      expect(MifareCardSize.k4.capacityBytes, 3440);
      expect(MifareCardSize.k4.payloadSize, 3408);
      expect(MifareCardSize.k1.capacityBytes, 752);
      expect(MifareCardSize.k1.payloadSize, 720);
      expect(usableBlockIndexes4k.sublist(0, 47), usableBlockIndexes);
      expect(MifareCardSize.k1.usableBlocks, usableBlockIndexes);
      expect(MifareCardSize.k4.usableBlocks, usableBlockIndexes4k);
    });

    test('no block 0, no trailers; 128 and 142 in, 143 out', () {
      final trailers = [
        for (var b = 3; b < 128; b += 4) b,
        for (var b = 143; b < 256; b += 16) b,
      ];
      for (final l in [usableBlockIndexes, usableBlockIndexes4k]) {
        expect(l.contains(0), isFalse);
        for (final t in trailers) {
          expect(l.contains(t), isFalse, reason: 'trailer $t');
        }
      }
      expect(usableBlockIndexes4k.contains(128), isTrue);
      expect(usableBlockIndexes4k.contains(142), isTrue);
      expect(usableBlockIndexes4k.contains(143), isFalse);
    });

    test('sector helpers', () {
      expect(sectorOf(127), 31);
      expect(sectorOf(128), 32);
      expect(sectorOf(143), 32);
      expect(sectorOf(144), 33);
      expect(sectorOf(255), 39);
      expect(firstBlockOfSector(33), 144);
      expect(firstBlockOfSector(31), 124);
      expect(isSectorTrailer(127), isTrue);
      expect(isSectorTrailer(143), isTrue);
      expect(isSectorTrailer(142), isFalse);
    });

    test('chunkToBlocks sizes', () {
      final b = bytesOf(752);
      final d = chunkToBlocks(b);
      final k = chunkToBlocks(b, size: MifareCardSize.k4);
      expect(k.length, d.length);
      for (var i = 0; i < d.length; i++) {
        expect(k[i].block, d[i].block);
        expect(k[i].data, d[i].data);
      }
      final big = chunkToBlocks(bytesOf(3000), size: MifareCardSize.k4);
      expect(big.length, 188);
      expect(big.last.block, usableBlockIndexes4k[187]);
      expect(() => chunkToBlocks(bytesOf(753)),
          throwsA(isA<MifareCapacityException>()));
      expect(() => chunkToBlocks(bytesOf(3441), size: MifareCardSize.k4),
          throwsA(isA<MifareCapacityException>()));
    });

    test('nfarTotalLength honours size', () {
      expect(() => nfarTotalLength(header(3000)), throwsFormatException);
      expect(nfarTotalLength(header(3000), size: MifareCardSize.k4), 3032);
      expect(nfarTotalLength(header(3408), size: MifareCardSize.k4), 3440);
      expect(() => nfarTotalLength(header(3409), size: MifareCardSize.k4),
          throwsFormatException);
    });

    test('writableCapacity', () {
      expect(writableCapacity(MifareCardSize.k4, allow4k: false), 752);
      expect(writableCapacity(MifareCardSize.k4, allow4k: true), 3440);
      expect(writableCapacity(MifareCardSize.k1, allow4k: true), 752);
    });
  });
}
