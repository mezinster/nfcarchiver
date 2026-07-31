import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_commands.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';

Uint8List _b(List<int> xs) => Uint8List.fromList(xs);

/// BleChameleonDevice cannot be unit-tested against real BLE, but its command
/// encoding and response parsing can — and that is where the bugs live. They
/// are pure functions for exactly that reason.
void main() {
  group('Mifare block commands', () {
    test('read packs keyType, block, key', () {
      expect(
        encodeReadBlock(4, factoryKeyA),
        equals([0x60, 0x04, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
      );
    });

    test('write appends the 16 data bytes after the same 8-byte prefix', () {
      final data = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final out = encodeWriteBlock(7, factoryKeyA, data);
      expect(out.length, 24);
      expect(out.sublist(0, 8), equals([0x60, 0x07, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]));
      expect(out.sublist(8), equals(data));
    });

    test('a key that is not 6 bytes is rejected before it reaches the wire', () {
      expect(() => encodeReadBlock(4, _b([1, 2, 3])), throwsA(anything));
    });

    test('a data block that is not 16 bytes is rejected', () {
      expect(() => encodeWriteBlock(4, factoryKeyA, _b([1, 2])), throwsA(anything));
    });
  });

  group('HF14A_RAW', () {
    test('option bits are packed MSB-first', () {
      // writeBitMSB: bit offset 0 is the MOST significant bit of the byte.
      // activateRfField=0x80, waitResponse=0x40, appendCrc=0x20,
      // autoSelect=0x10, keepRfField=0x08, checkResponseCrc=0x04.
      final b = encodeHf14aRaw(
        _b([0x30, 0x04]),
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: true,
      );
      expect(b[0], 0x20 | 0x10 | 0x04 | 0x40,
          reason: 'waitResponse defaults on');
    });

    test('activateRfField and keepRfField map to their own bits', () {
      final b = encodeHf14aRaw(_b([0x52]),
          activateRfField: true, keepRfField: true, dataBitLength: 7);
      expect(b[0] & 0x80, 0x80, reason: 'activateRfField');
      expect(b[0] & 0x08, 0x08, reason: 'keepRfField');
    });

    test('timeout follows the options byte, big-endian', () {
      final b = encodeHf14aRaw(_b([0x30, 0x00]));
      expect((b[1] << 8) | b[2], 1000, reason: 'default timeout');
    });

    test('a whole-byte frame normalises to 8 bits per byte', () {
      // dataBitLength = (len - 1) * 8 + ((bits + 7) % 8) + 1, so 0 maps to 8.
      final b = encodeHf14aRaw(_b([0x26]), dataBitLength: 0);
      expect((b[3] << 8) | b[4], 8);
    });

    test('a 7-bit frame is declared as 7 bits, not 8', () {
      // WUPA and REQA are 7-bit frames. Sending them as 8 bits gets no answer,
      // and the symptom on hardware is an inspector that never sees a card.
      final b = encodeHf14aRaw(_b([0x52]), dataBitLength: 7);
      expect((b[3] << 8) | b[4], 7);
    });

    test('a multi-byte frame counts all preceding bytes in full', () {
      final b = encodeHf14aRaw(_b([0x93, 0x20]), dataBitLength: 0);
      expect((b[3] << 8) | b[4], 16);
    });

    test('the frame bytes follow the 5-byte prefix verbatim', () {
      final frame = _b([0x30, 0x04]);
      final b = encodeHf14aRaw(frame);
      expect(b.length, 5 + frame.length);
      expect(b.sublist(5), equals(frame));
    });
  });

  group('HF14A_SCAN response', () {
    test('parses uidLen | uid | atqa | sak | atsLen | ats', () {
      final tag = parseScanResponse(
        _b([4, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x04, 0x08, 0]),
      )!;
      expect(tag.uid, equals([0xDE, 0xAD, 0xBE, 0xEF]));
      expect(tag.atqa, equals([0x00, 0x04]));
      expect(tag.sak, 0x08);
    });

    test('parses a 7-byte UID with a trailing ATS', () {
      final tag = parseScanResponse(
        _b([7, 4, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x44, 0x00, 2, 0x78, 0x77]),
      )!;
      expect(tag.uid.length, 7);
      expect(tag.sak, 0x00);
    });

    test('an empty response means no tag, not an error', () {
      // Polling an empty field is the normal state of a reader waiting for a
      // tap, so this must not throw.
      expect(parseScanResponse(_b([])), isNull);
    });

    test('a truncated record is rejected rather than half-read', () {
      expect(() => parseScanResponse(_b([4, 0xDE, 0xAD])), throwsA(anything));
    });
  });

  group('device mode', () {
    test('reader mode is encoded as a single byte', () {
      expect(encodeChangeDeviceMode(1), equals([0x01]));
    });
  });
}
