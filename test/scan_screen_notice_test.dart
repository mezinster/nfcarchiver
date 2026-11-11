import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/features/diagnostics/presentation/diagnostics_screen.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/screens/scan_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import 'support/fake_card_reader.dart';

/// Skips the on-disk session load; the screen only needs a scanning state.
/// A chunk index seen before comes back as a duplicate, like the real one.
class _ScanningNotifier extends RestoreNotifier {
  final _seen = <int>{};

  @override
  Future<void> startScanning() async {
    state = const RestoreScanning(sessions: []);
  }

  @override
  ScannedChunkInfo processChunk(Chunk chunk) {
    // Like the real one: a processed chunk replaces the scanning state, which
    // is what drops the previous error.
    state = const RestoreScanning(sessions: []);
    return ScannedChunkInfo(
      archiveId: 'test',
      chunkIndex: chunk.chunkIndex,
      totalChunks: chunk.totalChunks,
      isNew: _seen.add(chunk.chunkIndex),
    );
  }
}

Chunk _chunk(int index) => Chunk(
      archiveId: Uint8List(16),
      totalChunks: 12,
      chunkIndex: index,
      payload: Uint8List(0),
      crc32: 0,
    );

const _tag = NfcTagInfo(
  identifier: '04A1B2',
  capacity: 888,
  isWritable: true,
  isNdefCapable: true,
);

void main() {
  late FakeCardReader reader;

  Future<void> pumpScreen(WidgetTester tester,
      {Locale locale = const Locale('en')}) async {
    reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const ScanScreen()),
      GoRoute(
        path: diagnosticsRoute,
        builder: (_, __) => const Text('diagnostics-page'),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          restoreProvider.overrideWith((ref) => _ScanningNotifier()),
          nfcAvailableProvider.overrideWith((ref) async => true),
          nfcSessionProvider.overrideWith((ref) => NfcSessionNotifier(reader)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a tag without our data is a neutral notice that never halts',
      (tester) async {
    await pumpScreen(tester);
    for (var i = 0; i < 6; i++) {
      reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }

    expect(find.text('No NFC Archiver data on this tag'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.text('Details'), findsNothing);
    expect(find.text('Scan more tags'), findsNothing);
    expect(reader.readArms, 7);
  });

  testWidgets('a read failure shows the error card with a Details link',
      (tester) async {
    await pumpScreen(tester);
    reader.lastOnError!(const NfcFailure(NfcFailureKind.readFailed));
    await tester.pump();

    expect(find.text("Couldn't read this tag"), findsOneWidget);
    expect(find.text('Hold it still against the phone and try again.'),
        findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('Details'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('diagnostics-page'), findsOneWidget);
  });

  testWidgets('a later real error replaces the neutral notice', (tester) async {
    await pumpScreen(tester);
    reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    reader.lastOnError!(const NfcFailure(NfcFailureKind.readFailed));
    await tester.pump();

    expect(find.text('No NFC Archiver data on this tag'), findsNothing);
    expect(find.text("Couldn't read this tag"), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a chunk read clears the notice', (tester) async {
    await pumpScreen(tester);
    reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));
    await tester.pump();
    expect(find.text('No NFC Archiver data on this tag'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    reader.lastOnChunkRead!(_chunk(1), _tag);
    await tester.pump();

    expect(find.text('No NFC Archiver data on this tag'), findsNothing);
  });

  testWidgets('the hint follows the locale, not the wording of the text',
      (tester) async {
    await pumpScreen(tester, locale: const Locale('ru'));
    reader.lastOnError!(const NfcFailure(NfcFailureKind.detectionFailed));
    await tester.pump();

    final ru = await AppLocalizations.delegate.load(const Locale('ru'));
    expect(find.text(ru.nfcReadFailedHint), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('two quick neutral notices arm one session, not two',
      (tester) async {
    await pumpScreen(tester);
    reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));
    await tester.pump(const Duration(milliseconds: 100));
    reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(reader.readArms, 2);
  });
}
