import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nfc_archiver/features/archive/presentation/screens/write_progress_screen.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/nfc.dart';

/// A fake [NfcSessionNotifier] that never touches the platform channel: it
/// lets the test push an arbitrary [NfcSessionState] (as the real
/// `onTagTypeMismatch` callback would, deep inside a live NFC session) and
/// records whether `stopSession()` was called in response, without ever
/// calling `NfcRepository`/`NfcManager`.
class _FakeNfcSessionNotifier extends NfcSessionNotifier {
  int stopSessionCalls = 0;
  final endedTags = <String>[];

  @override
  void endTag(String message, {bool problem = false}) =>
      endedTags.add(problem ? 'problem: $message' : message);

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

  Future<_FakeNfcSessionNotifier> pumpScreen(
    WidgetTester tester, {
    ValueNotifier<bool>? show,
  }) async {
    final fakeNfc = _FakeNfcSessionNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nfcSessionProvider.overrideWith((ref) => fakeNfc)],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
          home: show == null
              ? const WriteProgressScreen()
              : ValueListenableBuilder<bool>(
                  valueListenable: show,
                  builder: (_, visible, __) => visible
                      ? const WriteProgressScreen()
                      : const SizedBox.shrink(),
                ),
        ),
      ),
    );
    await tester.pump();
    return fakeNfc;
  }

  // iOS gives its checkmark and haptic only when the sheet ends; left open,
  // a successful write was silent until the screen's later reset.
  testWidgets('a successful write ends the iOS sheet as a success',
      (tester) async {
    final fakeNfc = await pumpScreen(tester);
    fakeNfc.emit(const NfcSessionWriteSuccess(
      tagInfo: NfcTagInfo(
        identifier: '04A1B2',
        capacity: 888,
        isWritable: true,
        isNdefCapable: true,
      ),
      bytesWritten: 512,
    ));
    await tester.pump();

    expect(fakeNfc.endedTags, ['Tag Written!']);
    // Let the screen's auto-acknowledge timer run out.
    await tester.pump(const Duration(seconds: 2));
  });

  // Cancelling the sheet is the user's choice, not a write error.
  testWidgets('a stopped session shows no error', (tester) async {
    final fakeNfc = await pumpScreen(tester);
    fakeNfc.emit(const NfcSessionStopped(ScanStop.cancelled));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  // Swipe-back left the write session running, like the scan screen's did.
  testWidgets('leaving the screen stops the session', (tester) async {
    final show = ValueNotifier(true);
    final fakeNfc = await pumpScreen(tester, show: show);
    expect(fakeNfc.stopSessionCalls, 0);

    show.value = false;
    await tester.pump();
    await tester.pump();

    expect(fakeNfc.stopSessionCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
