import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/log/diagnostics.dart';
import 'core/log/logger.dart';
import 'core/providers/locale_provider.dart';
import 'features/nfc/data/phone_nfc_reader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  installErrorHooks(log);

  // Initialize SharedPreferences for locale persistence
  final prefs = await SharedPreferences.getInstance();

  // Bounded: a slow platform call must not hold the app on a blank screen;
  // on timeout the logger simply stays memory-only.
  final diagnostics = await startDiagnostics(
    log,
    locale: savedAppLocale(prefs)?.toLanguageTag(),
  ).timeout(const Duration(seconds: 3), onTimeout: () => null);

  // Query NFC hardware capabilities once before any session can start.
  await PhoneNfcReader().initCapabilities();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        diagnosticsFileProvider.overrideWithValue(diagnostics),
      ],
      child: const NfcArchiverApp(),
    ),
  );
}
