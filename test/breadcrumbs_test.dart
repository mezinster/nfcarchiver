import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/log/log_navigator_observer.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';

import 'support/fake_card_reader.dart';

class _FakeRestoreRepo implements RestoreRepository {
  final sessions = <String, RestoreSession>{};
  @override
  RestoreSession getSession(Uint8List archiveId) => sessions.putIfAbsent(
      archiveId.join(','), () => RestoreSession(archiveId: archiveId));
  @override
  List<RestoreSession> get activeSessions => sessions.values.toList();
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #persistSession) return Future<void>.value();
    return super.noSuchMethod(i);
  }
}

String _logText() => log.snapshot().map((e) => e.formatFull()).join('\n');

void main() {
  setUp(() => log.clear());

  testWidgets('navigator observer logs pushes and pops', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [LogNavigatorObserver()],
      routes: {'/': (_) => const Text('home'), '/next': (_) => const Text('n')},
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    log.clear();
    nav.pushNamed('/next');
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    final navs = log.snapshot().where((e) => e.scope == 'nav').toList();
    expect(navs.map((e) => e.message), ['open /next', 'back to /']);
  });

  testWidgets('go_router route names reach the observer (nested routes need a full-path name)', (tester) async {
    final router = GoRouter(
      observers: [LogNavigatorObserver()],
      routes: [
        GoRoute(
          path: '/',
          builder: (c, s) => const Text('home'),
          routes: [GoRoute(path: 'a', name: '/a', builder: (c, s) => const Text('a'))],
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.push('/a');
    await tester.pumpAndSettle();
    final msgs =
        log.snapshot().where((e) => e.scope == 'nav').map((e) => e.message);
    expect(msgs, containsAllInOrder(['open /', 'open /a']));
  });

  test('archive breadcrumbs never contain the file name or password', () async {
    final dir = await Directory.systemTemp.createTemp('crumbs');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tax-return-2026.pdf')
      ..writeAsBytesSync(List.filled(300, 7));

    final n = ArchiveNotifier();
    n.selectFile(
        filePath: file.path, fileName: 'tax-return-2026.pdf', fileSize: 300);
    n.setPassword('hunter2');
    n.configure(tagType: NfcTagType.ntag216, compress: true, encrypt: true);
    await n.prepareArchive();
    expect(n.state, isA<ArchiveReady>());

    var text = _logText();
    expect(text, contains('state ArchiveReady'));
    expect(text, contains('tagType=NTAG216'));
    for (final secret in ['tax-return', '.pdf', 'hunter2', dir.path]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }

    // An error whose message embeds the path must not leak it either.
    final bad = ArchiveNotifier();
    bad.selectFile(
        filePath: '${dir.path}/tax-return-gone.pdf',
        fileName: 'tax-return-gone.pdf',
        fileSize: 1);
    bad.configure(tagType: NfcTagType.ntag216);
    await bad.prepareArchive();
    final err = bad.state as ArchiveError;
    expect(err.message, contains('tax-return-gone'));
    text = _logText();
    expect(text, contains('state ArchiveError'));
    expect(text, isNot(contains('tax-return')));
  });

  test('restore breadcrumbs carry chunk counts', () {
    final n = RestoreNotifier(repository: _FakeRestoreRepo());
    final payload = Uint8List.fromList([1, 2, 3]);
    n.processChunk(Chunk(
      archiveId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
      totalChunks: 3,
      chunkIndex: 1,
      payload: payload,
      crc32: 0,
    ));
    final e = log.snapshot().lastWhere((e) => e.message == 'state RestoreScanning');
    expect(e.data, containsPair('chunk', 1));
    expect(e.data, containsPair('chunks', 3));
  });

  test('reader switches leave a breadcrumb', () async {
    final c = ReaderController(
      makePhone: () => FakeCardReader(name: 'p', supportsRawAccess: false),
      makeChameleon: (_) => FakeCardReader(name: 'c', supportsRawAccess: true),
    );
    log.clear();
    await c.select(ReaderKind.chameleon, deviceId: 'AA');
    final e = log.snapshot().singleWhere((e) => e.scope == 'reader');
    expect(e.data, {'kind': 'chameleon', 'connected': true});
  });
}
