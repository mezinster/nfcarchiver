import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/nfar_format.dart';
import '../providers/archive_provider.dart';

/// Screen for configuring archive settings.
class ArchiveSettingsScreen extends ConsumerStatefulWidget {
  const ArchiveSettingsScreen({super.key});

  @override
  ConsumerState<ArchiveSettingsScreen> createState() =>
      _ArchiveSettingsScreenState();
}

class _ArchiveSettingsScreenState extends ConsumerState<ArchiveSettingsScreen> {
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    // Initialize settings
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tagType = ref.read(selectedTagTypeProvider);
      final compress = ref.read(compressionEnabledProvider);
      final encrypt = ref.read(encryptionEnabledProvider);
      ref.read(archiveProvider.notifier).configure(
            tagType: tagType,
            compress: compress,
            encrypt: encrypt,
          );
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(archiveProvider);
    final tagType = ref.watch(selectedTagTypeProvider);
    final compress = ref.watch(compressionEnabledProvider);
    final encrypt = ref.watch(encryptionEnabledProvider);

    if (state is! ArchiveConfiguring && state is! ArchiveFileSelected) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: Text('No file selected')),
      );
    }

    final config = state is ArchiveConfiguring ? state : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archive Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/archive'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Tag type selection
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.nfc,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'NFC Tag Type',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ...NfcTagType.values
                      .where((t) => t != NfcTagType.custom)
                      .map((type) => RadioListTile<NfcTagType>(
                            title: Text(type.name),
                            subtitle:
                                Text('${type.capacity} bytes capacity'),
                            value: type,
                            groupValue: tagType,
                            onChanged: (value) {
                              if (value != null) {
                                ref.read(selectedTagTypeProvider.notifier).state =
                                    value;
                                _updateConfig(ref);
                              }
                            },
                          )),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Compression option
          Card(
            child: SwitchListTile(
              title: const Text('Enable Compression'),
              subtitle: const Text('Reduce size with GZIP compression'),
              secondary: Icon(
                Icons.compress,
                color: Theme.of(context).colorScheme.primary,
              ),
              value: compress,
              onChanged: (value) {
                ref.read(compressionEnabledProvider.notifier).state = value;
                _updateConfig(ref);
              },
            ),
          ),

          const SizedBox(height: 16),

          // Encryption option
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Enable Encryption'),
                  subtitle: const Text('Protect with AES-256-GCM'),
                  secondary: Icon(
                    Icons.lock,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  value: encrypt,
                  onChanged: (value) {
                    ref.read(encryptionEnabledProvider.notifier).state = value;
                    _updateConfig(ref);
                  },
                ),
                if (encrypt) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        hintText: 'Enter encryption password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                      ),
                      onChanged: (value) {
                        ref.read(archiveProvider.notifier).setPassword(value);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Estimate card
          if (config?.estimate != null) ...[
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Archive Estimate',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _EstimateRow(
                      label: 'Original size',
                      value: _formatSize(config!.fileSize),
                    ),
                    _EstimateRow(
                      label: 'Estimated processed size',
                      value: _formatSize(config.estimate!.estimatedProcessedSize),
                    ),
                    _EstimateRow(
                      label: 'Tags needed',
                      value: '${config.estimate!.chunksNeeded}',
                      highlight: true,
                    ),
                    _EstimateRow(
                      label: 'Payload per tag',
                      value: '${config.estimate!.payloadPerChunk} bytes',
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Start button
          FilledButton.icon(
            onPressed: () => _startArchive(context, ref),
            icon: const Icon(Icons.archive),
            label: const Text('Start Archiving'),
          ),
        ],
      ),
    );
  }

  void _updateConfig(WidgetRef ref) {
    final tagType = ref.read(selectedTagTypeProvider);
    final compress = ref.read(compressionEnabledProvider);
    final encrypt = ref.read(encryptionEnabledProvider);
    ref.read(archiveProvider.notifier).configure(
          tagType: tagType,
          compress: compress,
          encrypt: encrypt,
        );
  }

  Future<void> _startArchive(BuildContext context, WidgetRef ref) async {
    final encrypt = ref.read(encryptionEnabledProvider);
    if (encrypt && _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a password')),
      );
      return;
    }

    await ref.read(archiveProvider.notifier).prepareArchive();
    if (context.mounted) {
      context.go('/archive/write');
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _EstimateRow extends StatelessWidget {
  const _EstimateRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
          ),
        ],
      ),
    );
  }
}
