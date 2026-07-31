import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_repository.dart';

void main() {
  group('tagMediumMismatches', () {
    test('Mifare tap against a Mifare-configured archive is not a mismatch',
        () {
      expect(
        tagMediumMismatches(
          tappedIsMifare: true,
          configuredMedium: TagMedium.mifareClassic,
        ),
        isFalse,
      );
    });

    test('NDEF tap against an NDEF-configured archive is not a mismatch', () {
      expect(
        tagMediumMismatches(
          tappedIsMifare: false,
          configuredMedium: TagMedium.ndef,
        ),
        isFalse,
      );
    });

    test(
        'a Mifare tap against an NDEF-configured archive is the dead end '
        'a NTAG216/generic1k user hits with a Mifare card in hand', () {
      expect(
        tagMediumMismatches(
          tappedIsMifare: true,
          configuredMedium: TagMedium.ndef,
        ),
        isTrue,
      );
    });

    test('an NDEF tap against a Mifare-configured archive is also a mismatch',
        () {
      expect(
        tagMediumMismatches(
          tappedIsMifare: false,
          configuredMedium: TagMedium.mifareClassic,
        ),
        isTrue,
      );
    });
  });
}
