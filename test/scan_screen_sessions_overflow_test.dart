import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/screens/scan_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

List<RestoreSessionInfo> _sessions(int n) => [
      for (var i = 0; i < n; i++)
        RestoreSessionInfo(
          archiveId: '${i}abcdefg-0000-0000-000000000000',
          receivedCount: i.isEven ? 3 : 1,
          totalChunks: 3,
          isComplete: i.isEven,
          isEncrypted: i.isOdd,
          updatedAt: DateTime(2026, 9, 19, 12, i),
        ),
    ];

class _ScanningNotifier extends RestoreNotifier {
  _ScanningNotifier(this._sessions, {this.error});
  final List<RestoreSessionInfo> _sessions;
  final String? error;

  @override
  Future<void> startScanning() async {
    state = RestoreScanning(sessions: _sessions, lastError: error);
  }
}

Future<void> _pump(
  WidgetTester tester,
  List<RestoreSessionInfo> sessions, {
  String? error,
}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        restoreProvider
            .overrideWith((ref) => _ScanningNotifier(sessions, error: error)),
        nfcAvailableProvider.overrideWith((ref) async => false),
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

void main() {
  testWidgets('six archives in progress do not overflow a small phone',
      (tester) async {
    await _pump(tester, _sessions(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('nor do they together with an error banner', (tester) async {
    await _pump(tester, _sessions(6),
        error: 'Tag does not contain valid archive data');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last archive can be scrolled into reach', (tester) async {
    await _pump(tester, _sessions(6));
    tester.takeException(); // the overflow itself is the first test's subject

    final list = find.byKey(const Key('sessions-list'));
    expect(list, findsOneWidget);
    await tester.drag(list, const Offset(0, -2000));
    await tester.pump();

    final last = find.textContaining('5abcdefg');
    expect(last, findsWidgets);
    expect(tester.getRect(last.first).bottom, lessThanOrEqualTo(640));
  });
}
