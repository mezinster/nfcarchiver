import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
          const LanguageSelector(),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAboutDialog(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // NFC Status
              nfcAvailable.when(
                data: (available) => _NfcStatusBanner(isAvailable: available),
                loading: () => const _NfcStatusBanner(isLoading: true),
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
              Text(
                l10n.version,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.4),
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showAboutDialog(
      context: context,
      applicationName: l10n.appTitle,
      applicationVersion: '1.0.5',
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
      ],
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
                                .withOpacity(0.6),
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

    return storageInfo.when(
      data: (info) {
        if (info.fileCount == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => GoRouter.of(context).push('/files'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.storageUsage(
                          info.fileCount,
                          formatFileSize(info.totalBytes),
                        ),
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
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
