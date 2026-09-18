import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/file_picker_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// The "Configure archive" button must stay reachable while the keyboard is up.
///
/// The regression this covers: text mode laid the card, a `Spacer` and the
/// button out in a plain, unscrollable `Column`. The Scaffold shrinks its body
/// by the keyboard inset, so the Spacer collapsed to zero and the Column
/// overflowed — clipping the button off the bottom with no way to reach it.
/// Nothing about that was iOS-specific; Android resizes its body the same way
/// (`android:windowSoftInputMode="adjustResize"`).
void main() {
  const keyboardHeight = 336.0;
  const screenHeight = 800.0;

  testWidgets('the configure button stays on screen with the keyboard open',
      (tester) async {
    // The software keyboard, raised only once the text field has focus.
    final keyboard = ValueNotifier<double>(0);
    addTearDown(keyboard.dispose);

    tester.view.physicalSize = const Size(500 * 3, screenHeight * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<double>(
          valueListenable: keyboard,
          builder: (context, inset, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: EdgeInsets.only(bottom: inset),
            ),
            child: const FilePickerScreen(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Text'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      List.filled(24, 'a long sentence of text to archive').join(' '),
    );
    keyboard.value = keyboardHeight;
    await tester.pumpAndSettle();

    // A RenderFlex overflow is reported as a test exception.
    expect(tester.takeException(), isNull);

    final button = find.widgetWithText(FilledButton, 'Configure Archive');
    expect(button, findsOneWidget);
    expect(
      tester.getRect(button).bottom,
      lessThanOrEqualTo(screenHeight - keyboardHeight),
    );
  });
}
