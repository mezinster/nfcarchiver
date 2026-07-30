import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_availability.dart';

void main() {
  group('classifyNdefUnavailable', () {
    test('a tag exposing NfcA is a failed detection, not an unusable tag', () {
      // Android attaches the Ndef tech only if it completed NDEF detection at
      // discovery — reading the CC, walking the TLVs and parsing the message.
      // A brief or badly-coupled tap aborts that walk on a perfectly good tag,
      // which surfaces as no Ndef tech but NfcA still present.
      expect(
        classifyNdefUnavailable(hasNfcA: true, hasMifareUltralight: false),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('a tag exposing only MifareUltralight is also a failed detection', () {
      expect(
        classifyNdefUnavailable(hasNfcA: false, hasMifareUltralight: true),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('a tag exposing no NFC-A technology is genuinely not NDEF', () {
      expect(
        classifyNdefUnavailable(hasNfcA: false, hasMifareUltralight: false),
        NdefUnavailableReason.notNdefFormatted,
      );
    });

    test('the failed-detection message invites a retry', () {
      final message =
          messageFor(NdefUnavailableReason.detectionFailed);
      expect(message.toLowerCase(), contains('again'));
      // It must not tell the user to go find a different tag: the tag is fine.
      expect(message.toLowerCase(), isNot(contains('pre-formatted')));
    });

    test('the not-formatted message points at the tag, not a retry', () {
      final message =
          messageFor(NdefUnavailableReason.notNdefFormatted);
      expect(message.toLowerCase(), contains('ndef'));
      expect(message, isNot(equals(messageFor(NdefUnavailableReason.detectionFailed))));
    });
  });
}
