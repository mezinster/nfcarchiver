import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/write_progress_screen.dart';
import 'package:nfc_archiver/features/nfc/nfc.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

class _FakeNfcSessionNotifier extends NfcSessionNotifier {
  void emit(NfcSessionState next) => state = next;

  @override
  void stopSession() => state = const NfcSessionIdle();
}

/// Regression: a Mifare 1K on the phone radio reports no tag type, so the
/// medium used to fall back to NDEF and the re-chunk offered 680 B instead
/// of 720 B. The medium now comes from the archive's configured tag type.
void main() {
  testWidgets(
      '4K configured + 1K card with no tagInfo type: re-chunks at 720, not 680',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('rechunkmedium');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rnd = Random(2);
    final file = File('${dir.path}/a.bin')
      ..writeAsBytesSync(
          Uint8List.fromList(List.generate(5000, (_) => rnd.nextInt(256))));

    final archive = ArchiveNotifier();
    archive.selectFile(filePath: file.path, fileName: 'a.bin', fileSize: 5000);
    archive.configure(
        tagType: NfcTagType.mifareClassic4k, compress: false, encrypt: false);
    await tester.runAsync(() => archive.prepareArchive());
    expect(archive.state, isA<ArchiveReady>());
    archive.startWriting();

    final fakeNfc = _FakeNfcSessionNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nfcSessionProvider.overrideWith((ref) => fakeNfc),
          archiveProvider.overrideWith((ref) => archive),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('en')],
          home: WriteProgressScreen(),
        ),
      ),
    );
    await tester.pump();

    fakeNfc.emit(const NfcSessionTagTooSmall(
        requiredSize: 3440, detectedCapacity: 752));
    await tester.pumpAndSettle();

    // 5000 B / 720 = 7 chunks (680 would give 8).
    expect(find.textContaining('720'), findsWidgets);
    await tester.tap(find.text('Reconfigure'));
    await tester.pumpAndSettle();

    final sizes = (archive.state as ArchiveReady)
        .result
        .chunks
        .map((c) => c.payload.length)
        .toList();
    expect(sizes.every((s) => s <= 720), isTrue);
    expect(sizes, contains(720));
  });
}
