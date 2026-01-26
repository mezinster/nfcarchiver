import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/restore_provider.dart';

/// Screen for completing archive restoration.
class RestoreProgressScreen extends ConsumerStatefulWidget {
  const RestoreProgressScreen({super.key});

  @override
  ConsumerState<RestoreProgressScreen> createState() =>
      _RestoreProgressScreenState();
}

class _RestoreProgressScreenState
    extends ConsumerState<RestoreProgressScreen> {
  final _passwordController = TextEditingController();
  final _fileNameController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _fileNameController.text = 'restored_file';
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _fileNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(restoreProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.restoreArchive),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _handleBack(context),
        ),
      ),
      body: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, RestoreState state) {
    if (state is RestoreReady) {
      return _buildReadyView(context, state);
    }

    if (state is RestoreInProgress) {
      return _buildProgressView(context, state);
    }

    if (state is RestoreComplete) {
      return _buildCompleteView(context, state);
    }

    if (state is RestoreError) {
      return _buildErrorView(context, state);
    }

    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildReadyView(BuildContext context, RestoreReady state) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Success icon
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            l10n.allChunksReceived,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.chunksFromArchive(state.session.totalChunks),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          // File name input
          TextField(
            controller: _fileNameController,
            decoration: InputDecoration(
              labelText: l10n.fileName,
              hintText: l10n.fileNameHint,
              helperText: l10n.fileNameHelper,
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 16),

          // Password input (if encrypted)
          if (state.needsPassword) ...[
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.lock,
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          l10n.archiveIsEncrypted,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      decoration: InputDecoration(
                        labelText: l10n.password,
                        hintText: l10n.enterDecryptionPassword,
                        border: const OutlineInputBorder(),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
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
                        counterText:
                            l10n.charactersCount(_passwordController.text.length),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const Spacer(),

          // Restore button
          FilledButton.icon(
            onPressed: () => _restore(context, state),
            icon: const Icon(Icons.restore),
            label: Text(l10n.restoreArchive),
          ),

          const SizedBox(height: 16),

          // Back to scanning
          TextButton(
            onPressed: () {
              ref.read(restoreProvider.notifier).backToScanning();
              context.go('/restore');
            },
            child: Text(l10n.scanMoreTags),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressView(BuildContext context, RestoreInProgress state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            state.stage,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildCompleteView(BuildContext context, RestoreComplete state) {
    final l10n = AppLocalizations.of(context)!;

    // Check if this is a text note (special filename)
    final isTextNote = state.fileName == 'text_note.txt' ||
        state.result.originalFileName == 'text_note.txt';

    if (isTextNote) {
      return _buildTextCompleteView(context, state);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle,
            size: 96,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            l10n.archiveRestored,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(
            state.fileName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _formatSize(state.result.dataSize),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                ),
          ),

          if (state.result.savedPath != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.savedTo(state.result.savedPath!),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: 48),

          // Share button
          if (state.result.savedPath != null)
            FilledButton.icon(
              onPressed: () => _shareFile(state.result.savedPath!),
              icon: const Icon(Icons.share),
              label: Text(l10n.shareFile),
            ),

          const SizedBox(height: 16),

          OutlinedButton.icon(
            onPressed: () {
              ref.read(restoreProvider.notifier).reset();
              context.go('/');
            },
            icon: const Icon(Icons.home),
            label: Text(l10n.done),
          ),
        ],
      ),
    );
  }

  Widget _buildTextCompleteView(BuildContext context, RestoreComplete state) {
    final l10n = AppLocalizations.of(context)!;

    // Decode the text from UTF-8 bytes
    String restoredText;
    try {
      restoredText = utf8.decode(state.result.data);
    } catch (_) {
      restoredText = l10n.couldNotDecodeText;
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.check_circle,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.textRestored,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      _formatSize(state.result.dataSize),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6),
                          ),
                    ),
                  ],
                ),
              ),
              // Copy button
              IconButton.filled(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: restoredText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.textCopied)),
                  );
                },
                icon: const Icon(Icons.copy),
                tooltip: l10n.copyText,
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Text content card
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: SelectableText(
                    restoredText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    ref.read(restoreProvider.notifier).reset();
                    context.go('/');
                  },
                  icon: const Icon(Icons.home),
                  label: Text(l10n.done),
                ),
              ),
              if (state.result.savedPath != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _shareFile(state.result.savedPath!),
                    icon: const Icon(Icons.share),
                    label: Text(l10n.shareFile),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, RestoreError state) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            state.hasCorruptedChunks ? Icons.warning_amber : Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 24),
          Text(
            state.hasCorruptedChunks ? l10n.dataCorruptionDetected : l10n.restoreFailed,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(
            state.message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Different actions based on error type
          if (state.hasCorruptedChunks) ...[
            // CRC error - offer to rescan corrupted tags
            FilledButton.icon(
              onPressed: () {
                ref.read(restoreProvider.notifier).rescanCorruptedChunks();
                context.go('/restore');
              },
              icon: const Icon(Icons.nfc),
              label: Text(l10n.rescanTags(state.corruptedChunks.length)),
            ),
          ] else if (state.isDecryptionError && state.session != null) ...[
            // Decryption error - retry with different password
            FilledButton.icon(
              onPressed: () {
                _passwordController.clear();
                ref.read(restoreProvider.notifier).retryRestore();
              },
              icon: const Icon(Icons.lock_reset),
              label: Text(l10n.tryDifferentPassword),
            ),
          ] else if (state.canRetry && state.session != null) ...[
            // Other error with session preserved - retry
            FilledButton(
              onPressed: () {
                ref.read(restoreProvider.notifier).retryRestore();
              },
              child: Text(l10n.tryAgain),
            ),
          ],

          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              ref.read(restoreProvider.notifier).reset();
              context.go('/');
            },
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  void _restore(BuildContext context, RestoreReady state) {
    final l10n = AppLocalizations.of(context)!;
    if (state.needsPassword && _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.pleaseEnterThePassword)),
      );
      return;
    }

    // Pass null for fileName to use original filename from archive if available
    final userFileName = _fileNameController.text.trim();
    ref.read(restoreProvider.notifier).restoreArchive(
          password: state.needsPassword ? _passwordController.text : null,
          fileName: userFileName.isNotEmpty && userFileName != 'restored_file'
              ? userFileName
              : null,
        );
  }

  void _handleBack(BuildContext context) {
    final state = ref.read(restoreProvider);
    if (state is RestoreComplete) {
      ref.read(restoreProvider.notifier).reset();
      context.go('/');
    } else {
      ref.read(restoreProvider.notifier).backToScanning();
      context.go('/restore');
    }
  }

  Future<void> _shareFile(String path) async {
    await Share.shareXFiles([XFile(path)]);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
