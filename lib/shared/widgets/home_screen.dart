import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/nfc/presentation/providers/reader_provider.dart';
import '../../features/nfc/presentation/screens/reader_picker_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers/dev_options_provider.dart';
import '../../features/dev_options/presentation/dev_options_screen.dart';
import '../../features/diagnostics/presentation/diagnostics_screen.dart';
import '../../features/file_manager/presentation/providers/file_manager_provider.dart';
import '../../features/nfc/nfc.dart';
import '../utils/format_utils.dart';
import 'language_selector.dart';

/// Home screen with mode selection.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nfcAvailable = ref.watch(nfcAvailableProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          // The active reader, and the way to change it. Shown in the app bar
          // because it applies to every operation, not to one screen.
          Consumer(
            builder: (context, ref, _) {
              final reader = ref.watch(readerControllerProvider);
              return IconButton(
                tooltip: reader.kind == ReaderKind.chameleon
                    ? l10n.readerChameleon
                    : l10n.readerPhoneNfc,
                icon: Icon(
                  reader.kind == ReaderKind.chameleon
                      ? Icons.bluetooth_connected
                      : Icons.nfc,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ReaderPickerScreen(),
                  ),
                ),
              );
            },
          ),
          const LanguageSelector(),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAboutDialog(context, ref),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                ),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // NFC Status
                        nfcAvailable.when(
                          data: (available) =>
                              _NfcStatusBanner(isAvailable: available),
                          loading: () =>
                              const _NfcStatusBanner(isLoading: true),
                          error: (_, __) =>
                              const _NfcStatusBanner(isAvailable: false),
                        ),

                        const SizedBox(height: 32),

                        // Logo/Header
                        Icon(
                          Icons.nfc,
                          size: 80,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.mainHeading,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),

                        // Storage indicator
                        _StorageIndicator(),

                        const Spacer(),

                        // Archive button
                        _ModeCard(
                          icon: Icons.archive,
                          title: l10n.createArchive,
                          description: l10n.createArchiveDesc,
                          onTap: () => context.go('/archive'),
                        ),

                        const SizedBox(height: 16),

                        // Restore button
                        _ModeCard(
                          icon: Icons.restore,
                          title: l10n.restoreArchive,
                          description: l10n.restoreArchiveDesc,
                          onTap: () => context.go('/restore'),
                        ),

                        const Spacer(),

                        // Footer
                        const _VersionFooter(),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showAboutDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    final devUnlocked = ref.read(devOptionsProvider).unlocked;
    showAboutDialog(
      context: context,
      applicationName: l10n.appTitle,
      applicationVersion: '${info.version} (${l10n.buildLabel} ${info.buildNumber})',
      applicationIcon: Icon(
        Icons.nfc,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      ),
      children: [
        Text(l10n.aboutAppDescription),
        const SizedBox(height: 16),
        Text(l10n.aboutSupportedTags),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            GoRouter.of(context).push('/privacy-policy');
          },
          child: Text(l10n.privacyPolicy),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            GoRouter.of(context).push(diagnosticsRoute);
          },
          child: Text(l10n.diagnosticsLog),
        ),
        if (devUnlocked)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              GoRouter.of(context).push(devOptionsRoute);
            },
            child: Text(l10n.developerOptions),
          ),
      ],
    );
  }
}

/// Version line. Seven quick taps unlock the developer options (taps more
/// than 2 s apart start over); once unlocked, taps do nothing.
class _VersionFooter extends ConsumerStatefulWidget {
  const _VersionFooter();

  @override
  ConsumerState<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends ConsumerState<_VersionFooter> {
  static const _tapsToUnlock = 7;
  static const _idleReset = Duration(seconds: 2);

  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();
  int _taps = 0;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _onTap() {
    if (ref.read(devOptionsProvider).unlocked) return;
    _reset?.cancel();
    _taps++;
    if (_taps < _tapsToUnlock) {
      _reset = Timer(_idleReset, () => _taps = 0);
      return;
    }
    _taps = 0;
    ref.read(devOptionsProvider.notifier).unlock();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.developerOptionsUnlocked),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final versionText = snapshot.hasData
            ? l10n.versionFooter(
                snapshot.data!.version,
                snapshot.data!.buildNumber,
              )
            : l10n.copyright;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Text(
            versionText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4),
                ),
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }
}

class _NfcStatusBanner extends StatelessWidget {
  const _NfcStatusBanner({
    this.isAvailable = false,
    this.isLoading = false,
  });

  final bool isAvailable;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (isLoading) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.nfcChecking,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      color: isAvailable
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isAvailable ? Icons.check_circle : Icons.error,
              color: isAvailable
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isAvailable ? l10n.nfcAvailable : l10n.nfcUnavailable,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isAvailable
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onErrorContainer,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  size: 32,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageIndicator extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageInfo = ref.watch(storageInfoProvider);
    final l10n = AppLocalizations.of(context)!;

    final hasFiles = storageInfo.whenOrNull(
          data: (info) => info.fileCount > 0,
        ) ??
        false;
    final info = storageInfo.valueOrNull;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => GoRouter.of(context).push('/files'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  hasFiles ? Icons.folder : Icons.folder_open,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasFiles
                        ? l10n.storageUsage(
                            info!.fileCount,
                            formatFileSize(info.totalBytes),
                          )
                        : l10n.noArchivedFiles,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
