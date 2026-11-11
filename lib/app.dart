import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/log/log_navigator_observer.dart';
import 'core/providers/locale_provider.dart';
import 'features/archive/presentation/screens/archive_settings_screen.dart';
import 'features/dev_options/presentation/dev_options_screen.dart';
import 'features/diagnostics/presentation/diagnostics_screen.dart';
import 'features/file_manager/presentation/screens/file_manager_screen.dart';
import 'features/photo/presentation/photo_optimiser_screen.dart';
import 'features/archive/presentation/screens/file_picker_screen.dart';
import 'features/archive/presentation/screens/write_progress_screen.dart';
import 'features/restore/presentation/screens/restore_progress_screen.dart';
import 'features/restore/presentation/screens/scan_screen.dart';
import 'features/share_in/share_in_listener.dart';
import 'shared/theme/app_theme.dart';
import 'shared/widgets/home_screen.dart';
import 'shared/widgets/privacy_policy_screen.dart';

/// Router configuration.
final _router = GoRouter(
  initialLocation: '/',
  observers: [LogNavigatorObserver()],
  routes: [
    // Home
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),

    // Archive flow
    GoRoute(
      path: '/archive',
      builder: (context, state) => const FilePickerScreen(),
      routes: [
        GoRoute(
          path: 'optimise',
          // go_router logs a nested route by its last segment; the full
          // path keeps the nav breadcrumb unambiguous.
          name: '/archive/optimise',
          builder: (context, state) => const PhotoOptimiserScreen(),
        ),
        GoRoute(
          path: 'settings',
          // go_router logs a nested route by its last segment; the full
          // path keeps the nav breadcrumb unambiguous.
          name: '/archive/settings',
          builder: (context, state) => const ArchiveSettingsScreen(),
        ),
        GoRoute(
          path: 'write',
          // go_router logs a nested route by its last segment; the full
          // path keeps the nav breadcrumb unambiguous.
          name: '/archive/write',
          builder: (context, state) => const WriteProgressScreen(),
        ),
      ],
    ),

    // File manager
    GoRoute(
      path: '/files',
      builder: (context, state) => const FileManagerScreen(),
    ),

    // Diagnostics log
    GoRoute(
      path: diagnosticsRoute,
      builder: (context, state) => const DiagnosticsScreen(),
    ),

    // Developer options
    GoRoute(
      path: devOptionsRoute,
      builder: (context, state) => const DevOptionsScreen(),
    ),

    // Privacy policy
    GoRoute(
      path: '/privacy-policy',
      builder: (context, state) => const PrivacyPolicyScreen(),
    ),

    // Restore flow
    GoRoute(
      path: '/restore',
      builder: (context, state) => const ScanScreen(),
      routes: [
        GoRoute(
          path: 'complete',
          // go_router logs a nested route by its last segment; the full
          // path keeps the nav breadcrumb unambiguous.
          name: '/restore/complete',
          builder: (context, state) => const RestoreProgressScreen(),
        ),
      ],
    ),
  ],
);

/// Main application widget.
class NfcArchiverApp extends ConsumerWidget {
  const NfcArchiverApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userLocale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'NFC Archiver',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: _router,
      // Above the Navigator: it routes shared items through [_router].
      builder: (context, child) =>
          ShareInListener(router: _router, child: child!),
      // Localization
      locale: userLocale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedLocales,
    );
  }
}
