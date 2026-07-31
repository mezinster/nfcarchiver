import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
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
      expect(() => nfarTotalLength(header),
          throwsA(isA<FormatException>()));
    });

    test('nfarTotalLength accepts a payload landing exactly on capacity', () {
      final header = Uint8List(32)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01])
        ..[26] = 0x02
        ..[27] = 0xD0; // 720 bytes payload -> 32 + 720 = 752 (exact capacity)
      expect(nfarTotalLength(header), 752);
    });
  });
}
