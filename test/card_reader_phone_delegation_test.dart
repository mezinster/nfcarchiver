import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_repository.dart';
import 'package:nfc_archiver/features/nfc/data/phone_nfc_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';

/// The extraction's contract: PhoneNfcReader adds no behaviour of its own.
///
/// The real evidence that the phone path did not regress is that every
/// pre-existing test in this suite still passes untouched — these assertions
/// only pin the properties those tests cannot see.
void main() {
  test('PhoneNfcReader is a CardReader that names the phone radio', () {
    final r = PhoneNfcReader();
    expect(r, isA<CardReader>());
    expect(r.name, 'phone-nfc');
  });

  test('the phone radio can never do raw access', () {
    // A permanent property of the platform, not a missing feature: nfc_manager
    // exposes no raw anticollision or arbitrary block access, so the card
    // inspector can never run on it. This gate is what keeps the UI honest.
    expect(PhoneNfcReader().supportsRawAccess, isFalse);
  });

  test('connect and disconnect are no-ops, not errors', () async {
    // The phone's radio has no connection phase. Implementing them as no-ops
    // rather than throwing keeps callers free of platform conditionals.
    final r = PhoneNfcReader();
    await expectLater(r.connect(), completes);
    await expectLater(r.disconnect(), completes);
  });

  test('cooldown state is read through, not shadowed', () {
    // A second copy of this flag would drift from the repository's, and a
    // stale cooldown silently re-reads a card the app just wrote.
    final repo = NfcRepository.instance;
    final r = PhoneNfcReader(repo);
    expect(r.isInWriteCooldown, equals(repo.isInWriteCooldown));
    r.clearWriteCooldown();
    expect(r.isInWriteCooldown, isFalse);
  });
}
