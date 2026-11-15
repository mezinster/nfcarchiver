import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/archive_settings_screen.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_card_reader.dart';

/// An archive addresses its chunks with a uint16, so it can span at most
/// 65,535 tags. The settings screen used to show a larger count without
/// comment and leave Start enabled; the failure only surfaced while preparing.
void main() {
  // The most an NTAG216 archive can hold: 65,535 tags x 812 B.
  final ntag216Limit =
      NfarLimits.maxChunks * NfcTagType.ntag216.maxPayloadSize;
  const warning = 'Too large: this needs more than 65535 tags, '
      'the most one archive can span.';

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pumpSettings(
    WidgetTester tester, {
    required int fileSize,
    required bool compress,
  }) async {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      readerControllerProvider.overrideWith((ref) => ReaderController(
            makePhone: () => FakeCardReader(
                name: 'phone-nfc',
                supportsRawAccess: false,
                mifareClassic: false),
            makeChameleon: (_) => FakeCardReader(
                name: 'chameleon-ble',
                supportsRawAccess: true,
                mifareClassic: true),
          )),
    ]);
    addTearDown(c.dispose);
    // The estimate card and Start sit below the fold of the default 800x600
    // surface, where the lazy list never builds them.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    c.read(selectedTagTypeProvider.notifier).state = NfcTagType.ntag216;
    c.read(compressionEnabledProvider.notifier).state = compress;
    c.read(encryptionEnabledProvider.notifier).state = false;
    c.read(archiveProvider.notifier).selectFile(
          filePath: '/tmp/a.bin',
          fileName: 'a.bin',
          fileSize: fileSize,
        );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArchiveSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  FilledButton startButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.ancestor(
          of: find.text('Start Archiving'),
          matching: find.bySubtype<FilledButton>()));

  testWidgets('an archive within the limit shows no warning', (tester) async {
    // 'a.bin' adds a 7-byte filename wrapper, so leave room for it.
    await pumpSettings(tester, fileSize: ntag216Limit - 7, compress: false);

    expect(find.text('65535'), findsOneWidget);
    expect(find.text(warning), findsNothing);
    expect(startButton(tester).onPressed, isNotNull);
  });

  testWidgets('an exact count over the limit warns and disables Start',
      (tester) async {
    await pumpSettings(tester, fileSize: ntag216Limit - 6, compress: false);

    expect(find.text('65536'), findsOneWidget);
    expect(find.text(warning), findsOneWidget);
    expect(startButton(tester).onPressed, isNull);
  });

  testWidgets('a guessed count over the limit warns but leaves Start enabled',
      (tester) async {
    // With compression the size is assumed (70%); the real archive may be
    // smaller and fit, so the user is warned, not blocked.
    await pumpSettings(tester, fileSize: ntag216Limit * 2, compress: true);

    expect(find.text(warning), findsOneWidget);
    expect(startButton(tester).onPressed, isNotNull);
  });
}
