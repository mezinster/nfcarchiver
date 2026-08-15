import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/android_tech_list.dart';

/// Android reports a tapped tag's technologies as fully-qualified Java class
/// names. nfc_manager v3 flattened that into an untyped map whose keys the app
/// probed by hand (`tag.data['nfca']`); v4 exposes `NfcTagAndroid.techList`
/// directly, so the lookup moves here where it can be tested.
///
/// Getting this wrong is quiet rather than loud: a mis-spelled tech name simply
/// never matches, and the app decides a good tag lacks NfcA — which feeds
/// `classifyNdefUnavailable` and changes the advice shown to the user.
void main() {
  // A real Android NTAG215 tech list.
  const ntag215 = [
    'android.nfc.tech.NfcA',
    'android.nfc.tech.MifareUltralight',
    'android.nfc.tech.Ndef',
  ];

  group('androidHasTech', () {
    test('matches a tech present on the tag', () {
      expect(androidHasTech(ntag215, 'NfcA'), isTrue);
      expect(androidHasTech(ntag215, 'MifareUltralight'), isTrue);
    });

    test('does not match a tech the tag lacks', () {
      expect(androidHasTech(ntag215, 'MifareClassic'), isFalse);
    });

    test('matches on the full class name, not a bare substring', () {
      // 'NfcA' is a substring of 'android.nfc.tech.NfcAFoo'; a contains() check
      // would report a tech the tag does not have.
      expect(androidHasTech(['android.nfc.tech.NfcAFoo'], 'NfcA'), isFalse);
    });

    test('an empty tech list matches nothing', () {
      expect(androidHasTech(const [], 'NfcA'), isFalse);
    });
  });

  group('androidTechLabels', () {
    test('renders the short names the app displays', () {
      expect(androidTechLabels(ntag215), ['NfcA', 'MifareUltralight', 'Ndef']);
    });

    test('preserves the order the platform reported', () {
      expect(
        androidTechLabels(
            ['android.nfc.tech.Ndef', 'android.nfc.tech.NfcA']),
        ['Ndef', 'NfcA'],
      );
    });

    test('passes through a name that carries no package prefix', () {
      expect(androidTechLabels(['NfcB']), ['NfcB']);
    });
  });
}
