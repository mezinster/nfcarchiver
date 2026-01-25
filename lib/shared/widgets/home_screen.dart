import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/nfc/nfc.dart';

/// Home screen with mode selection.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nfcAvailable = ref.watch(nfcAvailableProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC Archiver'),
        actions: [
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
                'Store files across\nmultiple NFC tags',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),

              const Spacer(),

              // Archive button
              _ModeCard(
                icon: Icons.archive,
                title: 'Create Archive',
                description: 'Split a file into multiple NFC tags',
                onTap: () => context.go('/archive'),
              ),

              const SizedBox(height: 16),

              // Restore button
              _ModeCard(
                icon: Icons.restore,
                title: 'Restore Archive',
                description: 'Scan tags to restore a file',
                onTap: () => context.go('/restore'),
              ),

              const Spacer(),

              // Footer
              Text(
                'NFC Archiver v1.0.0',
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
    showAboutDialog(
      context: context,
      applicationName: 'NFC Archiver',
      applicationVersion: '1.0.0',
      applicationIcon: Icon(
        Icons.nfc,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      ),
      children: [
        const Text(
          'A distributed data archive system using NFC tags. '
          'Store files across multiple NFC tags and restore them later.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Supported tags: NTAG213/215/216, MIFARE Ultralight',
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
                'Checking NFC...',
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
                isAvailable ? 'NFC is available' : 'NFC is not available',
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
