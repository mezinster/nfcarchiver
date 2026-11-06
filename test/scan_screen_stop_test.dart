import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/screens/scan_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import 'support/fake_card_reader.dart';

/// Skips the on-disk session load; the screen only needs a scanning state.
/// A chunk index seen before comes back as a duplicate, like the real one.
class _ScanningNotifier extends RestoreNotifier {
  _ScanningNotifier({this.completesOn});

  /// The chunk index whose read completes the archive, like the real one does.
  final int? completesOn;
  final _seen = <int>{};

  @override
  Future<void> startScanning() async {
    state = const RestoreScanning(sessions: []);
  }

  @override
  ScannedChunkInfo processChunk(Chunk chunk) {
    if (chunk.chunkIndex == completesOn) {
      state = RestoreReady(session: RestoreSession(archiveId: chunk.archiveId));
    }
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

/// A stopped scan stays stopped until the user asks for more.
///
/// The screen re-arms after every error, which made iOS's Cancel useless: the
/// dismissed sheet came straight back, up to five times.
void main() {
  late FakeCardReader reader;

  Future<void> pumpScreen(WidgetTester tester) async {
    reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          restoreProvider.overrideWith((ref) => _ScanningNotifier()),
          nfcAvailableProvider.overrideWith((ref) async => true),
          nfcSessionProvider.overrideWith((ref) => NfcSessionNotifier(reader)),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: [Locale('en')],
          home: ScanScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final reason in ScanStop.values.where((r) => r != ScanStop.failed)) {
    testWidgets('after ${reason.name} it does not re-arm by itself',
        (tester) async {
      await pumpScreen(tester);
      expect(reader.readArms, 1);

      reader.lastOnStopped!(reason);
      await tester.pump(const Duration(seconds: 2));

      expect(reader.readArms, 1);
      expect(find.text('Scan more tags'), findsOneWidget);
    });
  }

  testWidgets('"Scan more tags" arms again', (tester) async {
    await pumpScreen(tester);
    reader.lastOnStopped!(ScanStop.cancelled);
    await tester.pump();

    await tester.tap(find.text('Scan more tags'));
    await tester.pump();
    await tester.pump();

    expect(reader.readArms, 2);
    expect(find.text('Scan more tags'), findsNothing);
  });

  // Five consecutive errors used to leave "Preparing scanner..." up forever.
  testWidgets('running out of retries stops with the button, not a spinner',
      (tester) async {
    await pumpScreen(tester);
    for (var i = 0; i < 5; i++) {
      reader.lastOnError!('System resource unavailable');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }

    expect(find.text('Scan more tags'), findsOneWidget);
    expect(find.text('Preparing scanner...'), findsNothing);
  });

  // The banner on the screen is hidden behind iOS's sheet: how the sheet
  // closes is all the user has to tell a new chunk from a duplicate.
  group('after each chunk', () {
    testWidgets('a new chunk ends the sheet as a success', (tester) async {
      await pumpScreen(tester);
      reader.lastOnChunkRead!(_chunk(2), _tag);
      await tester.pump();

      expect(reader.endedTags, ['Chunk 3 of 12']);
    });

    testWidgets('a duplicate ends the sheet as a problem', (tester) async {
      await pumpScreen(tester);
      reader.lastOnChunkRead!(_chunk(2), _tag);
      await tester.pump();
      reader.lastOnChunkRead!(_chunk(2), _tag);
      await tester.pump();

      expect(reader.endedTags,
          ['Chunk 3 of 12', 'problem: Chunk 3 of 12 already scanned']);
    });
  });

  // The last chunk navigates to the result screen. Re-arming anyway opened a
  // fresh NFC sheet on top of the result, 3 s later, on a real iPhone.
  testWidgets('the chunk that completes the archive does not re-arm',
      (tester) async {
    reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const ScanScreen()),
      GoRoute(
        path: '/restore/complete',
        builder: (_, __) => const Text('result'),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          restoreProvider.overrideWith((ref) => _ScanningNotifier(completesOn: 2)),
          nfcAvailableProvider.overrideWith((ref) async => true),
          nfcSessionProvider.overrideWith((ref) => NfcSessionNotifier(reader)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(reader.readArms, 1);

    reader.lastOnChunkRead!(_chunk(2), _tag);
    await tester.pumpAndSettle();

    expect(find.text('result'), findsOneWidget);
    expect(reader.endedTags, ['Chunk 3 of 12']);
    expect(reader.readArms, 1);
  });

  // Swipe-back and Android's back button pop the route without going through
  // the app bar's arrow, which was the only thing that stopped the scan. A
  // sheet could then open over whatever screen came next.
  testWidgets('leaving the screen any way stops the scan', (tester) async {
    reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Text('home'),
        routes: [
          GoRoute(path: 'scan', builder: (_, __) => const ScanScreen()),
        ],
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
          ],
          supportedLocales: const [Locale('en')],
        ),
      ),
    );
    // Fixed pumps: the scanning icon animates forever, so nothing settles.
    router.push('/scan');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(reader.readArms, 1);
    expect(reader.readStops, 0);

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('home'), findsOneWidget);
    expect(reader.readStops, 1);
    expect(tester.takeException(), isNull);
  });
}
