import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/nfc/ndef_bytes.dart';
import 'package:nfc_archiver/core/nfc/type2.dart';

import 'support/helpers.dart';

void main() {
  group('NDEF record', () {
    test('a chunk round-trips through the record codec', () {
      final chunk = validChunkBytes();
      expect(decodeNdefMime(encodeNdefMime(chunk)), equals(chunk));
    });

    test('the short-record form is used below 256 payload bytes', () {
      final r = encodeNdefMime(Uint8List(10));
      expect(r[0] & 0x10, 0x10, reason: 'SR flag set');
      expect(r[1], 33, reason: 'type length of the NFAR MIME string');
      expect(r[2], 10, reason: 'single-byte payload length');
    });

    test('the long-record form is used at 256 payload bytes and above', () {
      // Getting this boundary wrong corrupts every card larger than an
      // NTAG213, and is invisible on small test payloads.
      final r = encodeNdefMime(Uint8List(256));
      expect(r[0] & 0x10, 0, reason: 'SR flag clear');
      expect(decodeNdefMime(r).length, 256);
    });

    test('a foreign MIME type is rejected', () {
      final r = encodeNdefMime(Uint8List(4));
      r[5] ^= 0xff; // corrupt a byte of the type string
      expect(() => decodeNdefMime(r), throwsA(isA<NdefFormatException>()));
    });

    test('a non-media TNF is rejected', () {
      final r = encodeNdefMime(Uint8List(4));
      r[0] = (r[0] & ~0x07) | 0x01; // TNF = well-known
      expect(() => decodeNdefMime(r), throwsA(isA<NdefFormatException>()));
    });

    test('a payload running past the record is rejected', () {
      final r = encodeNdefMime(Uint8List(20));
      expect(
        () => decodeNdefMime(Uint8List.sublistView(r, 0, r.length - 5)),
        throwsA(isA<NdefFormatException>()),
      );
    });
  });

  group('Type-2 TLV', () {
    test('a chunk round-trips through NDEF and the TLV', () {
      final chunk = validChunkBytes();
      expect(decodeNdefMime(readType2Ndef(wrapType2Tlv(encodeNdefMime(chunk)))),
          equals(chunk));
    });

    test('the 1-byte length form is used below 255 NDEF bytes', () {
      final tlv = wrapType2Tlv(Uint8List(100));
      expect(tlv[0], 0x03);
      expect(tlv[1], 100);
      expect(tlv.last, 0xfe, reason: 'terminator');
    });

    test('the 3-byte length form is used at 255 NDEF bytes and above', () {
      final tlv = wrapType2Tlv(Uint8List(255));
      expect(tlv[0], 0x03);
      expect(tlv[1], 0xff);
      expect((tlv[2] << 8) | tlv[3], 255);
      expect(readType2Ndef(tlv).length, 255);
    });

    test('NULL TLVs are skipped', () {
      final inner = encodeNdefMime(validChunkBytes());
      final tlv = wrapType2Tlv(inner);
      final withNulls = Uint8List.fromList([0x00, 0x00, ...tlv]);
      expect(readType2Ndef(withNulls), equals(inner));
    });

    test('a lock-control TLV before the NDEF TLV is skipped', () {
      final inner = encodeNdefMime(validChunkBytes());
      // 0x01 (lock control), length 3, three value bytes — then the real TLV.
      final withLock = Uint8List.fromList(
          [0x01, 0x03, 0xAA, 0xBB, 0xCC, ...wrapType2Tlv(inner)]);
      expect(readType2Ndef(withLock), equals(inner));
    });

    test('an incomplete TLV throws rather than returning partial bytes', () {
      final tlv = wrapType2Tlv(encodeNdefMime(validChunkBytes()));
      expect(
        () => readType2Ndef(Uint8List.sublistView(tlv, 0, 8)),
        throwsA(isA<NdefFormatException>()),
      );
    });

    test('memory with no NDEF TLV at all throws', () {
      expect(() => readType2Ndef(Uint8List(32)),
          throwsA(isA<NdefFormatException>()));
    });
  });

  group('NTAG geometry', () {
    test('GET_VERSION storage bytes map to chips', () {
      Uint8List v(int storage) =>
          Uint8List.fromList([0, 4, 4, 2, 1, 0, storage, 3]);
      expect(detectNtagType(v(0x0f)), NtagType.ntag213);
      expect(detectNtagType(v(0x11)), NtagType.ntag215);
      expect(detectNtagType(v(0x13)), NtagType.ntag216);
      expect(detectNtagType(v(0x99)), isNull);
      expect(detectNtagType(Uint8List(3)), isNull, reason: 'too short to judge');
    });

    test('total pages include config and lock pages, not just user memory', () {
      expect(ntagTotalPages(NtagType.ntag213), 45);
      expect(ntagTotalPages(NtagType.ntag215), 135);
      expect(ntagTotalPages(NtagType.ntag216), 231);
      // User memory is strictly smaller — using it to size a dump would
      // silently truncate every card.
      expect(ntagUserBytes(NtagType.ntag215),
          lessThan(ntagTotalPages(NtagType.ntag215) * 4));
    });
  });
}
