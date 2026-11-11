import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/providers/dev_options_provider.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';
import 'package:nfc_archiver/features/dev_options/presentation/dev_options_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/widgets/home_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _container(SharedPreferences prefs) {
  final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(SharedPreferences prefs, Widget home, {GoRouter? router}) =>
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: router != null
          ? MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            )
          : MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: home,
            ),
    );

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
        appName: 'a',
        packageName: 'p',
        version: '1.2.3',
        buildNumber: '4',
        buildSignature: '');
  });

  test('fresh prefs: locked, 4K off', () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(await SharedPreferences.getInstance());
    expect(c.read(devOptionsProvider).unlocked, isFalse);
    expect(c.read(devOptionsProvider).mifare4k, isFalse);
    expect(c.read(mifare4kEnabledProvider), isFalse);
  });

  test('unlock and setMifare4k persist across containers', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = _container(prefs);
    await c.read(devOptionsProvider.notifier).unlock();
    await c.read(devOptionsProvider.notifier).setMifare4k(true);
    expect(c.read(mifare4kEnabledProvider), isTrue);

    final c2 = _container(prefs);
    expect(c2.read(devOptionsProvider).unlocked, isTrue);
    expect(c2.read(devOptionsProvider).mifare4k, isTrue);
    expect(prefs.getBool('dev.unlocked'), isTrue);
    expect(prefs.getBool('dev.mifare4k'), isTrue);
  });

  testWidgets('7th footer tap unlocks; About then offers Developer options',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
          path: devOptionsRoute,
          builder: (_, __) => const DevOptionsScreen()),
    ]);
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(prefs, const SizedBox(), router: router));
    await tester.pump();
    await tester.pump();

    final footer = find.textContaining('1.2.3');
    expect(footer, findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.tap(footer);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Developer options enabled'), findsNothing);

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Developer options'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(footer);
    await tester.pump();
    expect(find.text('Developer options enabled'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Developer options'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DevOptionsScreen), findsOneWidget);
  });

  testWidgets('taps more than 2 s apart do not accumulate', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(prefs, const HomeScreen()));
    await tester.pump();
    final footer = find.textContaining('1.2.3');
    for (var i = 0; i < 10; i++) {
      await tester.tap(footer);
      await tester.pump(const Duration(seconds: 3));
    }
    expect(find.text('Developer options enabled'), findsNothing);
  });

  testWidgets('DevOptionsScreen switch toggles mifare4kEnabledProvider',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_app(prefs, const DevOptionsScreen()));
    final container = ProviderScope.containerOf(
        tester.element(find.byType(DevOptionsScreen)));
    expect(container.read(mifare4kEnabledProvider), isFalse);
    expect(find.text('Mifare Classic 4K'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(container.read(mifare4kEnabledProvider), isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(container.read(mifare4kEnabledProvider), isFalse);
  });
}
