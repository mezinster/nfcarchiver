import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_availability.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';

void main() {
  group('classifyNdefUnavailable', () {
    test('a tag exposing NfcA is a failed detection, not an unusable tag', () {
      // Android attaches the Ndef tech only if it completed NDEF detection at
      // discovery — reading the CC, walking the TLVs and parsing the message.
      // A brief or badly-coupled tap aborts that walk on a perfectly good tag,
      // which surfaces as no Ndef tech but NfcA still present.
      expect(
        classifyNdefUnavailable(
          hasNfcA: true,
          hasMifareUltralight: false,
          deviceSupportsMifare: true,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('a tag exposing only MifareUltralight is also a failed detection', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: true,
          deviceSupportsMifare: true,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('a tag exposing no NFC-A technology is genuinely not NDEF', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: false,
          deviceSupportsMifare: true,
        ),
        NdefUnavailableReason.notNdefFormatted,
      );
    });

    test('a failed detection maps to detectionFailed (a retry)', () {
      // Distinct from notNdefFormatted: the tag is fine, the tap was not.
      expect(failureFor(NdefUnavailableReason.detectionFailed).kind,
          NfcFailureKind.detectionFailed);
    });

    test('a non-NDEF tag maps to notNdefFormatted', () {
      expect(failureFor(NdefUnavailableReason.notNdefFormatted).kind,
          NfcFailureKind.notNdefFormatted);
    });
  });

  group('mifareUnsupported', () {
    test('NfcA with no Ndef and no MifareClassic on an incapable phone', () {
      // A Mifare Classic card tapped on a phone whose controller cannot do
      // CRYPTO1 looks exactly like this. Reporting "try again" would invite
      // endless retries of something that can never succeed.
      expect(
        classifyNdefUnavailable(
          hasNfcA: true,
          hasMifareUltralight: false,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.mifareUnsupported,
      );
    });

    test('the same signature on a CAPABLE phone is a failed detection', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: true,
          hasMifareUltralight: false,
          deviceSupportsMifare: true,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('MifareUltralight present is always a failed detection', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: true,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('no NFC-A at all is still notNdefFormatted', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: false,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.notNdefFormatted,
      );
    });

    test('it maps to mifareUnsupported, not a retry', () {
      expect(failureFor(NdefUnavailableReason.mifareUnsupported).kind,
          NfcFailureKind.mifareUnsupported);
    });
  });
}
