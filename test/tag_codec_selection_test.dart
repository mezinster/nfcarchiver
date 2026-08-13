import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_repository.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_tag_codec.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_tag_codec.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// nfc_manager exposes a const NfcTag constructor explicitly for testing.
/// Duplicated from mifare_tag_codec_test.dart (see Task 6 brief: Dart test
/// files cannot cleanly import each other's private helpers) as lowerCamelCase
/// to avoid the non_constant_identifier_names ignore that file needed.
NfcTag fakeTag() => const NfcTag(data: <String, dynamic>{});

void main() {
  test('Mifare is tried before NDEF', () {
    // NDEF is never written onto Classic, so a tag exposing MifareClassic is
    // unambiguously ours to handle with the Mifare codec. Order matters: a
    // Classic card that happens to be NDEF-formatted by another app must still
    // route to Mifare, or we would read the wrong bytes.
    //
    // Asserts against NfcRepository.instance.codecs itself (not a local
    // literal) so reordering the production list actually fails this test.
    final codecs = NfcRepository.instance.codecs;
    expect(codecs.length, 2);
    expect(codecs[0], isA<MifareTagCodec>());
    expect(codecs[1], isA<NdefTagCodec>());
  });

  test('MifareTagCodec does not claim a tag with no Mifare IO', () {
    expect(MifareTagCodec((_) => null).supports(fakeTag()), isFalse);
  });
}
