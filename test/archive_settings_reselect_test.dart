import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/archive_settings_screen.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';
import 'package:nfc_archiver/features/share_in/share_in_listener.dart';
import 'package:nfc_archiver/features/share_in/share_inbox.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/utils/format_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_card_reader.dart';

class _QueueInbox extends ShareInbox {
  final queue = <SharedItem>[];
  void Function()? onAvailable;

  @override
  Future<SharedItem?> take() async => queue.isEmpty ? null : queue.removeAt(0);

  @override
  void listen(void Function() onShareAvailable) =>
      onAvailable = onShareAvailable;

  @override
  void stopListening() => onAvailable = null;
}

/// Records what Start would prepare instead of reading and chunking it.
class _RecordingArchive extends ArchiveNotifier {
  final prepared = <String?>[];

  @override
  Future<void> prepareArchive() async {
    final s = state;
    if (s is ArchiveConfiguring) prepared.add(s.filePath);
  }
}

/// A share arriving while Archive settings is open routes to the same
/// location; go_router keeps the screen's State, so its initState configure
/// does not run again. The screen must configure the new selection itself.
void main() {
  setUp(() {
    log.mirrorToConsole = false;
    log.clear();
  });
  tearDown(() => log.mirrorToConsole = true);

  File file(Directory dir, String name, int size) =>
      File('${dir.path}/$name')..writeAsBytesSync(List.filled(size, 7));

  testWidgets('a non-image share while settings is open is configured',
      (tester) async {
    // Tall enough that the whole settings list, estimate included, is built.
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final root = Directory.systemTemp.createTempSync('settings_reselect');
    addTearDown(() => root.deleteSync(recursive: true));
    final a = file(root, 'a.bin', 300);
    final shareDir = Directory('${root.path}/share_in/0f8fad5b')
      ..createSync(recursive: true);
    final b = file(shareDir, 'b.bin', 5000);

    final inbox = _QueueInbox();
    final archive = _RecordingArchive();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      readerControllerProvider.overrideWith((ref) => ReaderController(
            makePhone: () => FakeCardReader(
                name: 'phone-nfc', supportsRawAccess: false),
            makeChameleon: (_) => FakeCardReader(
                name: 'chameleon-ble', supportsRawAccess: true),
          )),
      shareInboxProvider.overrideWithValue(inbox),
      archiveProvider.overrideWith((_) => archive),
    ]);
    addTearDown(c.dispose);

    c.read(archiveProvider.notifier).selectFile(
        filePath: a.path, fileName: 'a.bin', fileSize: a.lengthSync());
    final router = GoRouter(initialLocation: '/archive/settings', routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(
          path: '/archive/settings',
          builder: (_, __) => const ArchiveSettingsScreen()),
      GoRoute(
          path: '/archive/write',
          builder: (_, __) => const Scaffold(body: Text('write'))),
      GoRoute(
          path: '/archive/optimise',
          builder: (_, __) => const Scaffold(body: Text('optimise'))),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            ShareInListener(router: router, child: child!),
      ),
    ));
    await tester.pumpAndSettle();

    expect(c.read(archiveProvider), isA<ArchiveConfiguring>());
    expect(find.text(formatFileSize(300)), findsOneWidget);

    inbox.queue.add(
        SharedItem(path: b.path, name: 'b.bin', isImage: false, count: 1));
    inbox.onAvailable!();
    await tester.pumpAndSettle();

    final state = c.read(archiveProvider);
    expect(state, isA<ArchiveConfiguring>());
    expect((state as ArchiveConfiguring).filePath, b.path);
    expect(state.estimate, isNotNull);
    expect(find.text(formatFileSize(5000)), findsWidgets);
    expect(find.text(formatFileSize(300)), findsNothing);

    final start = find.text('Start Archiving');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(archive.prepared, [b.path]);
    expect(find.text('write'), findsOneWidget);
  });
}
