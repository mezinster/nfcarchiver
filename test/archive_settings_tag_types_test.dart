import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/providers/dev_options_provider.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/archive_settings_screen.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import 'support/fake_card_reader.dart';

/// The settings screen offers the media the ACTIVE READER can write.
///
/// The regression these cover: the list was filtered on the phone's own NFC
/// controller, so an iPhone — which has no such controller capability at all —
/// never showed Mifare Classic, not even with a Chameleon connected. That is
/// backwards: the reader is iOS's only route to the medium.
void main() {
  late SharedPreferences defaultPrefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    defaultPrefs = await SharedPreferences.getInstance();
  });

  FakeCardReader phone() => FakeCardReader(
        name: 'phone-nfc',
        supportsRawAccess: false,
        mifareClassic: false, // an iPhone, or a non-NXP Android controller
      );

  FakeCardReader chameleon() => FakeCardReader(
        name: 'chameleon-ble',
        supportsRawAccess: true,
        mifareClassic: true,
      );

  ProviderContainer container({SharedPreferences? prefs}) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs ?? defaultPrefs),
      readerControllerProvider.overrideWith((ref) => ReaderController(
            makePhone: phone,
            makeChameleon: (_) => chameleon(),
          )),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpSettings(WidgetTester tester, ProviderContainer c) async {
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
  }

  testWidgets('the phone radio alone does not offer Mifare Classic',
      (tester) async {
    final c = container();
    c.read(archiveProvider.notifier).selectFile(
          filePath: '/tmp/a.bin',
          fileName: 'a.bin',
          fileSize: 100,
        );
    await pumpSettings(tester, c);

    expect(find.text('NTAG216'), findsOneWidget);
    expect(find.text('Mifare Classic 1K'), findsNothing);
  });

  testWidgets('tapping a tag type selects it', (tester) async {
    // The tiles carry no groupValue/onChanged of their own; selection lives
    // in the RadioGroup ancestor. Nothing else here taps a tile, so a group
    // that is not wired up would go unnoticed.
    final c = container();
    c.read(archiveProvider.notifier).selectFile(
          filePath: '/tmp/a.bin',
          fileName: 'a.bin',
          fileSize: 100,
        );
    await pumpSettings(tester, c);
    expect(c.read(selectedTagTypeProvider), isNot(NfcTagType.ntag213));

    await tester.ensureVisible(find.text('NTAG213'));
    await tester.tap(find.text('NTAG213'));
    await tester.pumpAndSettle();

    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag213);
  });

  testWidgets('a connected Chameleon puts Mifare Classic on the list',
      (tester) async {
    final c = container();
    c.read(archiveProvider.notifier).selectFile(
          filePath: '/tmp/a.bin',
          fileName: 'a.bin',
          fileSize: 100,
        );
    await c
        .read(readerControllerProvider.notifier)
        .select(ReaderKind.chameleon, deviceId: 'AA:BB');
    await pumpSettings(tester, c);

    expect(find.text('Mifare Classic 1K'), findsOneWidget);
  });

  testWidgets('dropping the reader resets a now-unwritable Mifare selection',
      (tester) async {
    // Otherwise the radio group shows nothing selected while the archive is
    // still configured for a medium this reader cannot write — the failure
    // would surface only at tap, several screens later.
    final c = container();
    c.read(archiveProvider.notifier).selectFile(
          filePath: '/tmp/a.bin',
          fileName: 'a.bin',
          fileSize: 100,
        );
    await c
        .read(readerControllerProvider.notifier)
        .select(ReaderKind.chameleon, deviceId: 'AA:BB');
    await pumpSettings(tester, c);

    c.read(selectedTagTypeProvider.notifier).state =
        NfcTagType.mifareClassic1k;
    await tester.pumpAndSettle();
    expect(c.read(selectedTagTypeProvider), NfcTagType.mifareClassic1k);

    await c.read(readerControllerProvider.notifier).disconnect();
    await tester.pumpAndSettle();

    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag216);
    expect(find.text('Mifare Classic 1K'), findsNothing);
  });

  group('4K behind the developer switch', () {
    Future<ProviderContainer> with4kOn(WidgetTester tester,
        {required bool chameleonReader}) async {
      SharedPreferences.setMockInitialValues({'dev.mifare4k': true});
      final prefs = await SharedPreferences.getInstance();
      final c = container(prefs: prefs);
      c.read(archiveProvider.notifier).selectFile(
            filePath: '/tmp/a.bin',
            fileName: 'a.bin',
            fileSize: 100,
          );
      if (chameleonReader) {
        await c
            .read(readerControllerProvider.notifier)
            .select(ReaderKind.chameleon, deviceId: 'AA:BB');
      }
      await pumpSettings(tester, c);
      return c;
    }

    testWidgets('turning the switch off resets a 4K selection to 1K',
        (tester) async {
      final c = await with4kOn(tester, chameleonReader: true);
      expect(find.text('Mifare Classic 4K'), findsOneWidget);

      c.read(selectedTagTypeProvider.notifier).state =
          NfcTagType.mifareClassic4k;
      await tester.pumpAndSettle();
      expect(c.read(selectedTagTypeProvider), NfcTagType.mifareClassic4k);

      await c.read(devOptionsProvider.notifier).setMifare4k(false);
      await tester.pumpAndSettle();

      expect(c.read(selectedTagTypeProvider), NfcTagType.mifareClassic1k);
      expect(find.text('Mifare Classic 4K'), findsNothing);
    });

    testWidgets('with a non-Mifare reader a 4K selection falls to NTAG216',
        (tester) async {
      final c = await with4kOn(tester, chameleonReader: false);
      expect(find.text('Mifare Classic 4K'), findsNothing);

      c.read(selectedTagTypeProvider.notifier).state =
          NfcTagType.mifareClassic4k;
      await tester.pumpAndSettle();

      expect(c.read(selectedTagTypeProvider), NfcTagType.ntag216);
    });
  });
}
