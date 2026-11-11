import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';
import 'package:nfc_archiver/features/nfc/presentation/nfc_failure_text.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Every failure a reader can report has words a user can read — and none of
/// them leak the exception text that used to reach the screen.
void main() {
  for (final code in AppLocalizations.supportedLocales) {
    test('every NfcFailureKind has text in ${code.languageCode}', () {
      final l10n = lookupAppLocalizations(code);
      for (final kind in NfcFailureKind.values) {
        final text = nfcFailureText(NfcFailure(kind), l10n);
        expect(text.trim(), isNotEmpty, reason: kind.name);
        expect(text, isNot(contains('Exception')), reason: kind.name);
        expect(text.toLowerCase(), isNot(contains('stacktrace')),
            reason: kind.name);
      }
    });
  }

  test('English copy for the headline kinds', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(nfcFailureText(const NfcFailure(NfcFailureKind.noArchiveData), l10n),
        'No NFC Archiver data on this tag');
    expect(nfcFailureText(const NfcFailure(NfcFailureKind.detectionFailed), l10n),
        nfcFailureText(const NfcFailure(NfcFailureKind.readFailed), l10n));
    expect(nfcFailureText(const NfcFailure(NfcFailureKind.nfcUnavailable), l10n),
        l10n.nfcUnavailable);
    expect(nfcFailureText(const NfcFailure(NfcFailureKind.unknown), l10n),
        l10n.somethingWentWrong);
  });

  test('isNeutral is true only for noArchiveData', () {
    for (final kind in NfcFailureKind.values) {
      expect(isNeutral(NfcFailure(kind)), kind == NfcFailureKind.noArchiveData,
          reason: kind.name);
    }
  });
}
