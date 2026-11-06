import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/polling_options.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// What each NFC session polls for.
///
/// On iOS, polling ISO 18092 (FeliCa) is only allowed when Info.plist lists
/// FeliCa system codes. Ours lists none, so asking for it got every session
/// invalidated on the first tap with "Missing required entitlement" — the
/// first error ever seen on a Core NFC build.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS does not poll FeliCa, which needs system codes we do not have', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(sessionPollingOptions(), isNot(contains(NfcPollingOption.iso18092)));
  });

  // NTAG and Mifare Classic are ISO 14443-A; ICODE is ISO 15693.
  test('iOS still polls ISO 14443 and ISO 15693', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      sessionPollingOptions(),
      {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
    );
  });

  // Android is validated on hardware with everything enabled; keep it so.
  test('Android polls every technology, as before', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(sessionPollingOptions(), NfcPollingOption.values.toSet());
  });
}
