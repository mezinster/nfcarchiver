import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// "Doesn't fit" counts two things; both take their plural form.
void main() {
  String fit(String locale, int tags, int needed) =>
      lookupAppLocalizations(Locale(locale)).photoDoesNotFit(tags, needed);

  test('English: one tag, many tags', () {
    expect(fit('en', 1, 2), "Doesn't fit in 1 tag — needs at least 2 tags");
    expect(fit('en', 3, 7), "Doesn't fit in 3 tags — needs at least 7 tags");
  });

  test('Russian: one / few / many', () {
    expect(
        fit('ru', 1, 2), 'Не помещается в 1 метку — нужно не меньше 2 меток');
    expect(
        fit('ru', 3, 21), 'Не помещается в 3 метки — нужно не меньше 21 метки');
    expect(
        fit('ru', 5, 6), 'Не помещается в 5 меток — нужно не меньше 6 меток');
  });

  test('Belarusian: "не менш за" takes the accusative, one / few / many', () {
    expect(fit('be', 1, 2),
        'Не змяшчаецца ў 1 метку — патрэбна не менш за 2 меткі');
    expect(fit('be', 3, 5),
        'Не змяшчаецца ў 3 меткі — патрэбна не менш за 5 метак');
    expect(fit('be', 5, 21),
        'Не змяшчаецца ў 5 метак — патрэбна не менш за 21 метку');
    expect(fit('be', 5, 24),
        'Не змяшчаецца ў 5 метак — патрэбна не менш за 24 меткі');
  });

  test('Polish: one / other', () {
    expect(fit('pl', 1, 2),
        'Nie mieści się na 1 tagu — potrzeba co najmniej 2 tagów');
  });

  test('every locale renders both numbers', () {
    for (final l in AppLocalizations.supportedLocales) {
      final text = lookupAppLocalizations(l).photoDoesNotFit(4, 9);
      expect(text, contains('4'), reason: l.languageCode);
      expect(text, contains('9'), reason: l.languageCode);
    }
  });
}
