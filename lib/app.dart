import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/archive/presentation/screens/archive_settings_screen.dart';
import 'features/archive/presentation/screens/file_picker_screen.dart';
import 'features/archive/presentation/screens/write_progress_screen.dart';
import 'features/restore/presentation/screens/restore_progress_screen.dart';
import 'features/restore/presentation/screens/scan_screen.dart';
import 'shared/theme/app_theme.dart';
import 'shared/widgets/home_screen.dart';

/// Router configuration.
final _router = GoRouter(
  initialLocation: '/',
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
          path: 'settings',
          builder: (context, state) => const ArchiveSettingsScreen(),
        ),
        GoRoute(
          path: 'write',
          builder: (context, state) => const WriteProgressScreen(),
        ),
      ],
    ),

    // Restore flow
    GoRoute(
      path: '/restore',
      builder: (context, state) => const ScanScreen(),
      routes: [
        GoRoute(
          path: 'complete',
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
    return MaterialApp.router(
      title: 'NFC Archiver',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
