import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
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

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
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
}
