import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// "Continue with N tags" takes the plural form of its count.
void main() {
  String label(String locale, int count) =>
      lookupAppLocalizations(Locale(locale)).photoContinueWithTags(count);

  test('English: one tag, many tags', () {
    expect(label('en', 1), 'Continue with 1 tag');
    expect(label('en', 12), 'Continue with 12 tags');
  });

  test('Russian: one / few / many', () {
    expect(label('ru', 1), 'Продолжить с 1 меткой');
    expect(label('ru', 3), 'Продолжить с 3 метками');
    expect(label('ru', 12), 'Продолжить с 12 метками');
    expect(label('ru', 21), 'Продолжить с 21 меткой');
  });

  test('Ukrainian, Belarusian, Polish: one / few', () {
    expect(label('uk', 1), 'Продовжити з 1 міткою');
    expect(label('uk', 3), 'Продовжити з 3 мітками');
    expect(label('be', 1), 'Працягнуць з 1 меткай');
    expect(label('be', 3), 'Працягнуць з 3 меткамі');
    expect(label('pl', 1), 'Dalej z 1 tagiem');
    expect(label('pl', 3), 'Dalej z 3 tagami');
    expect(label('pl', 12), 'Dalej z 12 tagami');
  });

  test('every locale renders the count', () {
    for (final l in AppLocalizations.supportedLocales) {
      expect(
          lookupAppLocalizations(l).photoContinueWithTags(17), contains('17'),
          reason: l.languageCode);
    }
  });
}
