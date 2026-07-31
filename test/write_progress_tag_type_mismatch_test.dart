import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nfc_archiver/features/archive/presentation/screens/write_progress_screen.dart';
import 'package:nfc_archiver/features/nfc/nfc.dart';

/// A fake [NfcSessionNotifier] that never touches the platform channel: it
/// lets the test push an arbitrary [NfcSessionState] (as the real
/// `onTagTypeMismatch` callback would, deep inside a live NFC session) and
/// records whether `stopSession()` was called in response, without ever
/// calling `NfcRepository`/`NfcManager`.
class _FakeNfcSessionNotifier extends NfcSessionNotifier {
  int stopSessionCalls = 0;

  void emit(NfcSessionState next) {
    state = next;
  }

  @override
  void stopSession() {
    stopSessionCalls++;
    state = const NfcSessionIdle();
  }
}

void main() {
  testWidgets(
      'a tag-type mismatch stops the NFC session (regression for the '
      'reader staying armed after the error snackbar)', (tester) async {
    final fakeNfc = _FakeNfcSessionNotifier();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nfcSessionProvider.overrideWith((ref) => fakeNfc),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: WriteProgressScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(fakeNfc.stopSessionCalls, 0);

    // Simulate what NfcRepository.startWriteSession's onTagTypeMismatch
    // callback would push into state after a Mifare/NDEF mismatch tap.
    fakeNfc.emit(const NfcSessionTagTypeMismatch(
      tappedMedium: 'Mifare Classic',
      configuredMedium: 'NTAG213/215/216',
    ));
    await tester.pump();

    // The screen's listener must stop the session -- matching what
    // _showRechunkDialog already does for NfcSessionTagTooSmall -- so the
    // reader doesn't stay armed with the stale chunk closure once the error
    // snackbar is up.
    expect(fakeNfc.stopSessionCalls, 1);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
