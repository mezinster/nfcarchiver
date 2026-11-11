import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/log/diagnostics.dart';
import 'package:nfc_archiver/core/log/diagnostics_file.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/core/services/file_actions_service.dart';
import 'package:nfc_archiver/features/diagnostics/presentation/diagnostics_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/widgets/home_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nfc_archiver/core/providers/locale_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

LogEntry _e(LogLevel level, String msg, {String? detail}) => LogEntry(
    seq: 1,
    at: DateTime.utc(2026, 11, 11, 10, 0, 0),
    level: level,
    scope: 'nfc',
    message: msg,
    detail: detail);

Future<void> _until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// Pumps (letting real I/O run) until [finder] matches, or fails after ~3 s.
Future<void> settleUntil(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  await tester.pump();
  expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
}

void main() {
  late Directory dir;
  late DiagnosticsFile file;
  late List<XFile> shared;
  late List<String> sharedContent;

  setUp(() async {
    PackageInfo.setMockInitialValues(
        appName: 'a',
        packageName: 'p',
        version: '1.2.3',
        buildNumber: '4',
        buildSignature: '');
    dir = await Directory.systemTemp.createTemp('diagscreen');
    file = DiagnosticsFile(dir: Directory('${dir.path}/logs'));
    file.writeLine(
        '=== NFC Archiver 1.2.3 (4) · test · en · session start 2026-11-11T10:00:00.000Z ===');
    file.add(_e(LogLevel.info, 'hello world'));
    file.add(_e(LogLevel.error, 'boom', detail: 'PlatformException(x)'));
    await file.flush();
    shared = [];
    sharedContent = [];
  });

  tearDown(() => dir.delete(recursive: true));

  Widget app({Widget? home}) => ProviderScope(
        overrides: [
          diagnosticsFileProvider.overrideWithValue(file),
          diagnosticsTempDirProvider.overrideWithValue(() async => dir),
          fileActionsProvider
              .overrideWithValue(FileActionsService(sharer: (files) async {
            shared.addAll(files);
            for (final f in files) {
              sharedContent.add(await File(f.path).readAsString());
            }
          })),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: home ?? const DiagnosticsScreen(),
        ),
      );

  testWidgets('shows persisted lines including an error\'s detail',
      (tester) async {
    await tester.pumpWidget(app());
    await settleUntil(tester, find.textContaining('hello world'));
    expect(find.textContaining('hello world'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('    PlatformException(x)'), findsOneWidget);
  });

  testWidgets('Warnings & errors hides info but keeps detail', (tester) async {
    await tester.pumpWidget(app());
    await settleUntil(tester, find.textContaining('hello world'));
    await tester.tap(find.text('Warnings & errors'));
    await tester.pump();
    expect(find.textContaining('hello world'), findsNothing);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('    PlatformException(x)'), findsOneWidget);
  });

  testWidgets('Share hands a nfc-archiver-log-*.txt to FileActionsService',
      (tester) async {
    await tester.pumpWidget(app());
    await settleUntil(tester, find.textContaining('hello world'));
    await tester.tap(find.byIcon(Icons.ios_share));
    await _until(tester, () => sharedContent.isNotEmpty);
    expect(shared, hasLength(1));
    expect(shared.single.mimeType, 'text/plain');
    expect(shared.single.path, contains('nfc-archiver-log-'));
    expect(sharedContent.single, startsWith('=== NFC Archiver'));
    expect(sharedContent.single, contains('hello world'));
  });

  testWidgets('Clear asks first, then empties the log', (tester) async {
    await tester.pumpWidget(app());
    await settleUntil(tester, find.textContaining('hello world'));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hello world'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await settleUntil(tester, find.text('Nothing logged yet.'));
    expect(find.text('Nothing logged yet.'), findsOneWidget);
  });

  testWidgets('About dialog has a Diagnostics log entry that opens the screen',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
          path: diagnosticsRoute,
          builder: (_, __) => const DiagnosticsScreen()),
    ]);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          diagnosticsFileProvider.overrideWithValue(file),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ));
    });
    await tester.pump();
    await tester.tap(find.byIcon(Icons.info_outline));
    await settleUntil(tester, find.text('Diagnostics log'));
    await tester.tap(find.text('Diagnostics log'));
    await settleUntil(tester, find.byType(DiagnosticsScreen));
    expect(find.byType(DiagnosticsScreen), findsOneWidget);
  });

  group('degraded sink', () {
    late DiagnosticsFile broken;

    setUp(() async {
      // A file where the log directory should be: every I/O call fails.
      File('${dir.path}/blocker').writeAsStringSync('x');
      broken = DiagnosticsFile(dir: Directory('${dir.path}/blocker/logs'));
      broken.add(_e(LogLevel.info, 'lost'));
      await broken.flush();
      expect(broken.degraded, isTrue);
      log.clear();
      log.mirrorToConsole = false;
      log.info('nfc', 'in-memory-line');
      file = broken;
    });

    tearDown(() {
      log.mirrorToConsole = true;
      log.clear();
    });

    testWidgets('the screen shows the in-memory lines', (tester) async {
      await tester.pumpWidget(app());
      await settleUntil(tester, find.textContaining('in-memory-line'));
      expect(find.text('Nothing logged yet.'), findsNothing);
    });

    testWidgets('Share exports the in-memory lines', (tester) async {
      await tester.pumpWidget(app());
      await settleUntil(tester, find.textContaining('in-memory-line'));
      await tester.tap(find.byIcon(Icons.ios_share));
      await _until(tester, () => sharedContent.isNotEmpty);
      expect(shared, hasLength(1));
      expect(sharedContent.single, startsWith('=== NFC Archiver'));
      expect(sharedContent.single, contains('exported 20'));
      expect(sharedContent.single, contains('in-memory-line'));
    });
  });
}
