import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/privacy_policy_url.dart';

void main() {
  test('English is at the root', () {
    expect(privacyPolicyUrl(const Locale('en')).toString(),
        'https://nfcarchiver.com/docs/privacy/');
  });

  test('every other app language has its own folder', () {
    final others =
        AppLocalizations.supportedLocales.where((l) => l.languageCode != 'en');
    expect(others, isNotEmpty);
    for (final l in others) {
      expect(privacyPolicyUrl(l).toString(),
          'https://nfcarchiver.com/docs/${l.languageCode}/privacy/');
    }
  });

  test('a language the docs lack opens English', () {
    expect(privacyPolicyUrl(const Locale('de')).toString(),
        'https://nfcarchiver.com/docs/privacy/');
  });

  test('a country variant uses its language', () {
    expect(privacyPolicyUrl(const Locale('ru', 'BY')).toString(),
        'https://nfcarchiver.com/docs/ru/privacy/');
  });
}
