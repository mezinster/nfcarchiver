import 'package:flutter/widgets.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Where the full privacy policy lives on the web.
///
/// The page is built from `site-docs/` and served at
/// `https://nfcarchiver.com/docs/`: English at `privacy/`, every other app
/// language at `<code>/privacy/`. Moving or renaming that page breaks this
/// link in shipped apps; `test/privacy_policy_url_test.dart` is the guard.
///
/// A language the docs lack (the app itself falls back to English there)
/// opens English, never a `/docs/<code>/` that would 404.
Uri privacyPolicyUrl(Locale locale) {
  const base = 'https://nfcarchiver.com/docs/';
  final code = locale.languageCode;
  final docsLanguages =
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
  if (code == 'en' || !docsLanguages.contains(code)) {
    return Uri.parse('${base}privacy/');
  }
  return Uri.parse('$base$code/privacy/');
}
