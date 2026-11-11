import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/mifare/sak.dart';

void main() {
  test('classifySak', () {
    expect(classifySak(0x08), TagKind.classic1k);
    for (final s in [0x18, 0x38, 0x98]) {
      expect(classifySak(s), TagKind.classic4k);
    }
    expect(classifySak(0x00), TagKind.ntag);
    for (final s in [0x19, 0x09, 0x28, 0x20]) {
      expect(classifySak(s), TagKind.unsupported,
          reason: '0x${s.toRadixString(16)}');
    }
  });

  test('cardSizeFor', () {
    expect(cardSizeFor(TagKind.classic1k), MifareCardSize.k1);
    expect(cardSizeFor(TagKind.classic4k), MifareCardSize.k4);
    expect(cardSizeFor(TagKind.ntag), isNull);
    expect(cardSizeFor(TagKind.unsupported), isNull);
  });
}
