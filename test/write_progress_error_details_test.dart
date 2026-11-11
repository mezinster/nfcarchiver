import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/write_progress_screen.dart';
import 'package:nfc_archiver/features/diagnostics/presentation/diagnostics_screen.dart';
import 'package:nfc_archiver/features/nfc/nfc.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

class _FakeNfc extends NfcSessionNotifier {
  void emit(NfcSessionState next) => state = next;
}

void main() {
  testWidgets('a write failure offers Details in its snackbar', (tester) async {
    final fake = _FakeNfc();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const WriteProgressScreen()),
      GoRoute(
        path: diagnosticsRoute,
        builder: (_, __) => const Text('diagnostics-page'),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nfcSessionProvider.overrideWith((ref) => fake)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
        ),
      ),
    );
    await tester.pump();

    fake.emit(const NfcSessionError(
        failure: NfcFailure(NfcFailureKind.writeFailed)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('diagnostics-page'), findsOneWidget);
  });
}
