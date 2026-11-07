import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/widgets/privacy_policy_screen.dart';

const _enUrl = 'https://nfcarchiver.com/docs/privacy/';

Future<void> _pump(
  WidgetTester t, {
  Locale locale = const Locale('en'),
  required UrlOpener openUrl,
}) async {
  await t.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: PrivacyPolicyScreen(openUrl: openUrl),
  ));
  await t.pump();
}

void main() {
  testWidgets('shows the summary and the full-policy URL', (t) async {
    await _pump(t, openUrl: (_) async => true);
    expect(find.textContaining('collects no data'), findsOneWidget);
    final url = find.byType(SelectableText);
    expect(url, findsOneWidget);
    expect(t.widget<SelectableText>(url).data, _enUrl);
  });

  testWidgets('the button opens the policy for the app language', (t) async {
    Uri? recorded;
    await _pump(t, locale: const Locale('ru'), openUrl: (u) async {
      recorded = u;
      return true;
    });
    final ru = await AppLocalizations.delegate.load(const Locale('ru'));
    await t.tap(find.text(ru.privacyPolicyOpenFull));
    await t.pump();
    expect(recorded, Uri.parse('https://nfcarchiver.com/docs/ru/privacy/'));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed launch says so and keeps the URL visible', (t) async {
    await _pump(t, openUrl: (_) async => false);
    await t.tap(find.text('Open full policy'));
    await t.pump();
    expect(
        find.descendant(
            of: find.byType(SnackBar), matching: find.textContaining(_enUrl)),
        findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('a launcher that throws is treated as a failed launch',
      (t) async {
    await _pump(t, openUrl: (_) async => throw PlatformException(code: 'x'));
    await t.tap(find.text('Open full policy'));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(
        find.descendant(
            of: find.byType(SnackBar), matching: find.textContaining(_enUrl)),
        findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
