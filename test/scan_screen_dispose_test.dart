import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/screens/scan_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Skips the on-disk session load; the screen only needs a scanning state.
class _ScanningNotifier extends RestoreNotifier {
  @override
  Future<void> startScanning() async {
    state = const RestoreScanning(sessions: []);
  }
}

void main() {
  testWidgets(
      'leaving the screen while the reader is still answering "are you '
      'available?" touches nothing of the dead widget', (tester) async {
    // A BLE reader can take a moment to answer; backing out in that window
    // used to resume into AppLocalizations.of(context) and ref.read on a
    // disposed widget.
    final available = Completer<bool>();
    final showScreen = ValueNotifier(true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          restoreProvider.overrideWith((ref) => _ScanningNotifier()),
          nfcAvailableProvider.overrideWith((ref) => available.future),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
          home: ValueListenableBuilder<bool>(
            valueListenable: showScreen,
            builder: (_, show, __) =>
                show ? const ScanScreen() : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    showScreen.value = false;
    await tester.pump();

    available.complete(false);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
