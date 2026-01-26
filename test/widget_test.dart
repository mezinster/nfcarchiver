import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nfc_archiver/app.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';

void main() {
  testWidgets('App starts successfully', (WidgetTester tester) async {
    // Initialize mock SharedPreferences
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    // Build our app and trigger a frame.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const NfcArchiverApp(),
      ),
    );

    // Allow localizations to load (use pump instead of pumpAndSettle
    // because NFC provider has async loading that won't settle)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify that the home screen loads (checking for app title in either language)
    // Use findsWidgets because both title bar and footer have matching text
    expect(
      find.textContaining(RegExp(r'NFC (Archiver|Архиватор)')),
      findsWidgets,
    );
  });
}
