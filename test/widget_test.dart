import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:nfc_archiver/app.dart';

void main() {
  testWidgets('App starts successfully', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: NfcArchiverApp(),
      ),
    );

    // Verify that the home screen loads
    expect(find.text('NFC Archiver'), findsOneWidget);
  });
}
