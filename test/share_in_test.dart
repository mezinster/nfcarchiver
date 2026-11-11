import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:path/path.dart' as p;
import 'package:nfc_archiver/core/models/archive_metadata.dart' show ArchiveMetadata;
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/features/archive/data/archive_repository.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/photo/presentation/photo_optimiser_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/share_in/share_in_listener.dart';
import 'package:nfc_archiver/features/share_in/share_inbox.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Each queued entry is returned (a [SharedItem] or null) or thrown.
class FakeShareInbox extends ShareInbox {
  final queue = <Object?>[];
  int calls = 0;
  Completer<void>? gate;
  void Function()? onAvailable;

  @override
  Future<SharedItem?> take() async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    if (queue.isEmpty) return null;
    final next = queue.removeAt(0);
    if (next is Exception) throw next;
    return next as SharedItem?;
  }

  @override
  void listen(void Function() onShareAvailable) =>
      onAvailable = onShareAvailable;

  @override
  void stopListening() => onAvailable = null;
}

ArchiveResult _result() {
  Chunk chunk(int i) => Chunk(
        archiveId: Uint8List(16),
        totalChunks: 2,
        chunkIndex: i,
        payload: Uint8List(4),
        crc32: 0,
      );
  return ArchiveResult(
    metadata: ArchiveMetadata(
      id: Uint8List(16),
      originalFileName: 'x.bin',
      originalSize: 8,
      totalChunks: 2,
      chunkPayloadSize: 4,
    ),
    chunks: [chunk(0), chunk(1)],
    originalSize: 8,
    processedSize: 8,
    wasCompressed: false,
    wasEncrypted: false,
    processedData: Uint8List(8),
    fileName: 'x.bin',
    flags: 0,
  );
}

/// Holds a fixed state from the start; nothing else about it matters here.
class _FixedArchive extends ArchiveNotifier {
  _FixedArchive(ArchiveState s) {
    state = s;
  }
}

class _FixedRestore extends RestoreNotifier {
  _FixedRestore(RestoreState s) {
    state = s;
  }
}

class _Shell {
  _Shell(this.container, this.router, this.inbox);
  final ProviderContainer container;
  final GoRouter router;
  final FakeShareInbox inbox;
  String get path => router.routerDelegate.currentConfiguration.uri.path;
}

Future<_Shell> _pumpShell(
  WidgetTester tester, {
  FakeShareInbox? inbox,
  ArchiveState? archive,
  RestoreState? restore,
}) async {
  final fake = inbox ?? FakeShareInbox();
  final container = ProviderContainer(overrides: [
    shareInboxProvider.overrideWithValue(fake),
    if (archive != null)
      archiveProvider.overrideWith((_) => _FixedArchive(archive)),
    if (restore != null)
      restoreProvider.overrideWith((_) => _FixedRestore(restore)),
  ]);
  addTearDown(container.dispose);
  Widget page(String name) => Scaffold(body: Text('page $name'));
  final router = GoRouter(initialLocation: '/', routes: [
    GoRoute(path: '/', builder: (_, __) => page('/')),
    GoRoute(path: '/archive/optimise', builder: (_, __) => page('optimise')),
    GoRoute(path: '/archive/settings', builder: (_, __) => page('settings')),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          ShareInListener(router: router, child: child!),
    ),
  ));
  await tester.pumpAndSettle();
  return _Shell(container, router, fake);
}

/// A shared copy laid out the way the native side leaves it:
/// `<tmp>/share_in/<uuid>/<name>`.
File _sharedFile(String name) {
  final root = Directory.systemTemp.createTempSync('share_in_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final dir = Directory('${root.path}/share_in/0f8fad5b')
    ..createSync(recursive: true);
  return File('${dir.path}/$name')..writeAsBytesSync(List.filled(10, 1));
}

void main() {
  setUp(() {
    log.mirrorToConsole = false;
    log.clear();
  });
  tearDown(() => log.mirrorToConsole = true);

  /// Nothing about the shared file (name, path) may reach the log.
  void expectLogFreeOf(File f) {
    for (final e in log.snapshot()) {
      final line = e.formatFull();
      expect(line, isNot(contains(p.basename(f.path))));
      expect(line, isNot(contains(f.parent.path)));
    }
  }

  group('busy guard', () {
    test('archiveWorkInProgress', () {
      final r = _result();
      expect(archiveWorkInProgress(const ArchiveInitial()), isFalse);
      expect(
          archiveWorkInProgress(const ArchiveFileSelected(
              filePath: 'a', fileName: 'a', fileSize: 1)),
          isFalse);
      expect(
          archiveWorkInProgress(ArchiveReady(
              result: r, currentChunkIndex: 0, writtenChunks: const {})),
          isFalse);
      expect(
          archiveWorkInProgress(ArchiveReady(
              result: r, currentChunkIndex: 1, writtenChunks: const {0})),
          isTrue);
      expect(
          archiveWorkInProgress(ArchiveWriting(
              result: r, currentChunkIndex: 0, writtenChunks: const {})),
          isFalse);
      expect(
          archiveWorkInProgress(ArchiveWriting(
              result: r, currentChunkIndex: 1, writtenChunks: const {0})),
          isTrue);
    });

    test('restoreWorkInProgress', () {
      expect(restoreWorkInProgress(const RestoreInitial()), isFalse);
      expect(restoreWorkInProgress(const RestoreScanning()), isFalse);
      expect(
          restoreWorkInProgress(RestoreScanning(sessions: [
            RestoreSessionInfo(
              archiveId: 'id',
              receivedCount: 1,
              totalChunks: 2,
              isComplete: false,
              isEncrypted: false,
              updatedAt: DateTime(2026),
            ),
          ])),
          isTrue);
      expect(
          restoreWorkInProgress(const RestoreInProgress(archiveId: 'id')),
          isTrue);
    });
  });

  testWidgets('cold-start image lands on the optimiser', (tester) async {
    final f = _sharedFile('IMG_1.HEIC');
    final inbox = FakeShareInbox()
      ..queue.add(SharedItem(
          path: f.path, name: 'IMG_1.HEIC', isImage: true, count: 1));
    final shell = await _pumpShell(tester, inbox: inbox);

    expect(shell.path, '/archive/optimise');
    final pending = shell.container.read(pendingPhotoProvider)!;
    expect(pending.path, f.path);
    expect(pending.name, 'IMG_1.HEIC');
    expect(pending.size, 10);
    expect(find.byType(SnackBar), findsNothing);
    expect(log.snapshot(), isNotEmpty);
    expectLogFreeOf(f);
  });

  testWidgets('a non-image lands on Archive settings', (tester) async {
    final f = _sharedFile('doc.pdf');
    final inbox = FakeShareInbox()
      ..queue.add(
          SharedItem(path: f.path, name: 'doc.pdf', isImage: false, count: 1));
    final shell = await _pumpShell(tester, inbox: inbox);

    expect(shell.path, '/archive/settings');
    final s = shell.container.read(archiveProvider);
    expect(s, isA<ArchiveFileSelected>());
    expect((s as ArchiveFileSelected).fileSize, 10);
    expect(s.fileName, 'doc.pdf');
  });

  testWidgets('a non-image clears a waiting photo; an image clears a selection',
      (tester) async {
    final doc = _sharedFile('doc.pdf');
    final img = _sharedFile('a.jpg');
    final shell = await _pumpShell(tester);
    shell.container.read(pendingPhotoProvider.notifier).state =
        const PendingPhoto(path: '/old.jpg', size: 1);

    shell.inbox.queue.add(
        SharedItem(path: doc.path, name: 'doc.pdf', isImage: false, count: 1));
    shell.inbox.onAvailable!();
    await tester.pumpAndSettle();
    expect(shell.container.read(pendingPhotoProvider), isNull);
    expect(shell.container.read(archiveProvider), isA<ArchiveFileSelected>());

    shell.inbox.queue.add(
        SharedItem(path: img.path, name: 'a.jpg', isImage: true, count: 1));
    shell.inbox.onAvailable!();
    await tester.pumpAndSettle();
    expect(shell.container.read(archiveProvider), isA<ArchiveInitial>());
    expect(shell.container.read(pendingPhotoProvider)?.path, img.path);
    expect(shell.path, '/archive/optimise');
  });

  testWidgets('count 3 shows shareOnlyFirst with 3', (tester) async {
    final f = _sharedFile('doc.pdf');
    final inbox = FakeShareInbox()
      ..queue.add(
          SharedItem(path: f.path, name: 'doc.pdf', isImage: false, count: 3));
    await _pumpShell(tester, inbox: inbox);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('3'), findsOneWidget);
    expect(find.textContaining('NFC Archiver'), findsOneWidget);
  });

  group('busy archive', () {
    ArchiveState writing() => ArchiveWriting(
        result: _result(), currentChunkIndex: 1, writtenChunks: const {0});

    testWidgets('cancel deletes the copy and leaves the archive alone',
        (tester) async {
      final f = _sharedFile('doc.pdf');
      final inbox = FakeShareInbox()
        ..queue.add(SharedItem(
            path: f.path, name: 'doc.pdf', isImage: false, count: 1));
      final shell = await _pumpShell(tester, inbox: inbox, archive: writing());

      expect(find.text('Start a new archive?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(f.existsSync(), isFalse);
      expect(f.parent.existsSync(), isFalse,
          reason: 'the emptied share_in/<uuid> folder goes too');
      expect(f.parent.parent.existsSync(), isTrue,
          reason: 'share_in itself stays');
      final s = shell.container.read(archiveProvider);
      expect(s, isA<ArchiveWriting>());
      expect((s as ArchiveWriting).writtenChunks, {0});
      expect(shell.path, '/');
      expectLogFreeOf(f);
    });

    testWidgets('confirm resets and routes', (tester) async {
      final f = _sharedFile('doc.pdf');
      final inbox = FakeShareInbox()
        ..queue.add(SharedItem(
            path: f.path, name: 'doc.pdf', isImage: false, count: 1));
      final shell = await _pumpShell(tester, inbox: inbox, archive: writing());

      await tester.tap(find.text('Discard and continue'));
      await tester.pumpAndSettle();

      expect(f.existsSync(), isTrue);
      expect(shell.container.read(archiveProvider), isA<ArchiveFileSelected>());
      expect(shell.path, '/archive/settings');
    });
  });

  testWidgets('a restore in progress asks too; confirm resets it',
      (tester) async {
    final f = _sharedFile('doc.pdf');
    final inbox = FakeShareInbox()
      ..queue.add(
          SharedItem(path: f.path, name: 'doc.pdf', isImage: false, count: 1));
    final container = await _pumpShell(tester,
        inbox: inbox, restore: const RestoreInProgress(archiveId: 'id'));

    expect(find.text('Start a new archive?'), findsOneWidget);
    await tester.tap(find.text('Discard and continue'));
    await tester.pumpAndSettle();
    expect(container.container.read(restoreProvider), isA<RestoreInitial>());
    expect(container.path, '/archive/settings');
  });

  testWidgets('an unreadable share shows a localized message, not the error',
      (tester) async {
    final inbox = FakeShareInbox()
      ..queue.add(PlatformException(code: 'share_unreadable', message: 'boom'));
    final shell = await _pumpShell(tester, inbox: inbox);

    expect(find.text("The shared item couldn't be read."), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
    expect(shell.path, '/');
    expect(
        log.snapshot().where(
            (e) => e.level == LogLevel.error && e.scope == 'share'),
        hasLength(1),
        reason: 'reported through log.report');
  });

  testWidgets('any other failure shows somethingWentWrong', (tester) async {
    final inbox = FakeShareInbox()
      ..queue.add(PlatformException(code: 'other', message: 'boom'));
    await _pumpShell(tester, inbox: inbox);

    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('resume takes; two rapid resumes take once while pending',
      (tester) async {
    final shell = await _pumpShell(tester);
    final inbox = shell.inbox;
    expect(inbox.calls, 1, reason: 'cold start, after the first frame');

    inbox.gate = Completer<void>();
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(inbox.calls, 2);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    inbox.onAvailable!();
    await tester.pump();
    expect(inbox.calls, 2, reason: 'one take in flight at a time');

    inbox.gate!.complete();
    inbox.gate = null;
    await tester.pumpAndSettle();
    // Requests made while one was in flight are honoured once afterwards,
    // so a share that arrived meanwhile isn't left waiting for the next resume.
    expect(inbox.calls, 3);
  });

  testWidgets('dispose stops listening', (tester) async {
    final shell = await _pumpShell(tester);
    expect(shell.inbox.onAvailable, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(shell.inbox.onAvailable, isNull);
  });
}
