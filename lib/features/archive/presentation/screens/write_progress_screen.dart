import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/nfar_format.dart';
import '../../../nfc/nfc.dart';
import '../providers/archive_provider.dart';

/// Screen for writing chunks to NFC tags.
class WriteProgressScreen extends ConsumerStatefulWidget {
  const WriteProgressScreen({super.key});

  @override
  ConsumerState<WriteProgressScreen> createState() =>
      _WriteProgressScreenState();
}

class _WriteProgressScreenState extends ConsumerState<WriteProgressScreen> {
  @override
  void initState() {
    super.initState();
    _listenToNfcSession();
  }

  void _listenToNfcSession() {
    ref.listenManual(nfcSessionProvider, (previous, next) {
      if (next is NfcSessionWriteSuccess) {
        if (next.waitingForRemoval) {
          // Show "remove tag" prompt - will be handled by UI
          // Auto-acknowledge after delay to prevent sticking
          Future.delayed(const Duration(milliseconds: 1500), () {
            if (mounted) {
              final currentState = ref.read(nfcSessionProvider);
              if (currentState is NfcSessionWriteSuccess &&
                  currentState.waitingForRemoval) {
                ref.read(nfcSessionProvider.notifier).acknowledgeTagRemoval();
              }
            }
          });
        } else {
          // Tag removed, proceed to next chunk
          ref.read(archiveProvider.notifier).markChunkWritten();
          ref.read(nfcSessionProvider.notifier).reset();
        }
      } else if (next is NfcSessionTagTooSmall) {
        // Tag is too small - offer to rechunk
        ref.read(archiveProvider.notifier).cancelWriting();
        _showRechunkDialog(context, next.detectedCapacity, next.requiredSize);
      } else if (next is NfcSessionError) {
        // Error writing
        ref.read(archiveProvider.notifier).writeError(next.message);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.message)),
        );
      }
    });
  }

  Future<void> _showRechunkDialog(
    BuildContext context,
    int detectedCapacity,
    int requiredSize,
  ) async {
    ref.read(nfcSessionProvider.notifier).stopSession();

    final archiveState = ref.read(archiveProvider);
    final readyState = archiveState is ArchiveReady ? archiveState : null;
    final canRechunk = readyState != null && readyState.writtenChunks.isEmpty;

    // Calculate new chunk count if we rechunk
    final newPayloadSize = NfcTagType.maxPayloadForCapacity(detectedCapacity);
    int? newChunkCount;
    if (canRechunk) {
      final dataSize = readyState.result.processedSize;
      newChunkCount = newPayloadSize > 0
          ? (dataSize + newPayloadSize - 1) ~/ newPayloadSize
          : null;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tag Too Small'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This tag has $detectedCapacity bytes available, '
              'but the chunk needs $requiredSize bytes.',
            ),
            const SizedBox(height: 16),
            if (canRechunk && newChunkCount != null && newPayloadSize > 0) ...[
              const Text(
                'Would you like to reconfigure the archive for this tag size?',
              ),
              const SizedBox(height: 8),
              Text(
                'This will split the data into $newChunkCount smaller chunks '
                '($newPayloadSize bytes each).',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.6),
                    ),
              ),
            ] else if (!canRechunk) ...[
              Text(
                'Cannot reconfigure: chunks have already been written.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else ...[
              Text(
                'This tag is too small to store any data.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Use Different Tag'),
          ),
          if (canRechunk && newChunkCount != null && newPayloadSize > 0)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reconfigure'),
            ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      final newCount = ref
          .read(archiveProvider.notifier)
          .rechunkForDetectedCapacity(detectedCapacity);

      if (newCount != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reconfigured: now using $newCount tags'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to reconfigure archive'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(archiveProvider);
    final nfcState = ref.watch(nfcSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Writing to Tags'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => _showCancelDialog(context),
        ),
      ),
      body: _buildBody(context, state, nfcState),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ArchiveState state,
    NfcSessionState nfcState,
  ) {
    // Show "remove tag" prompt after successful write
    if (nfcState is NfcSessionWriteSuccess && nfcState.waitingForRemoval) {
      return _buildRemoveTagView(context, nfcState);
    }

    if (state is ArchivePreparing) {
      return _buildPreparingView(context, state);
    }

    if (state is ArchiveReady) {
      return _buildReadyView(context, state, nfcState);
    }

    if (state is ArchiveWriting) {
      return _buildWritingView(context, state);
    }

    if (state is ArchiveComplete) {
      return _buildCompleteView(context, state);
    }

    if (state is ArchiveError) {
      return _buildErrorView(context, state);
    }

    return const Center(child: Text('Unexpected state'));
  }

  Widget _buildPreparingView(BuildContext context, ArchivePreparing state) {
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
          const SizedBox(height: 8),
          Text(
            state.fileName,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyView(
    BuildContext context,
    ArchiveReady state,
    NfcSessionState nfcState,
  ) {
    final isWaiting = nfcState is NfcSessionWaiting;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Progress indicator
          _ProgressCard(
            current: state.writtenCount,
            total: state.totalChunks,
            progress: state.progress,
          ),

          const SizedBox(height: 24),

          // Current chunk info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    isWaiting ? Icons.nfc : Icons.nfc_outlined,
                    size: 64,
                    color: isWaiting
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isWaiting
                        ? 'Hold tag near device'
                        : 'Ready to write tag ${state.currentChunkIndex + 1}',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Chunk ${state.currentChunkIndex + 1} of ${state.totalChunks}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${state.currentChunk.payload.length} bytes',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),

          const Spacer(),

          // Write button
          if (!isWaiting)
            FilledButton.icon(
              onPressed: () => _startWriting(context, ref, state),
              icon: const Icon(Icons.nfc),
              label: const Text('Write to Tag'),
            )
          else
            OutlinedButton(
              onPressed: () {
                ref.read(nfcSessionProvider.notifier).stopSession();
              },
              child: const Text('Cancel'),
            ),

          const SizedBox(height: 16),

          // Skip button
          if (!isWaiting && state.writtenCount < state.totalChunks - 1)
            TextButton(
              onPressed: () {
                // Skip to next chunk
                ref.read(archiveProvider.notifier).markChunkWritten();
              },
              child: const Text('Skip this tag'),
            ),
        ],
      ),
    );
  }

  Widget _buildWritingView(BuildContext context, ArchiveWriting state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            'Writing chunk ${state.currentChunkIndex + 1}...',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildRemoveTagView(
      BuildContext context, NfcSessionWriteSuccess state) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              size: 80,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Tag Written!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Remove the tag from your device',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '${state.bytesWritten} bytes written',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6),
                  ),
            ),
            const SizedBox(height: 32),
            // Pulsing indicator
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                ref.read(nfcSessionProvider.notifier).acknowledgeTagRemoval();
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteView(BuildContext context, ArchiveComplete state) {
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
            'Archive Complete!',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(
            '${state.totalTags} tags written',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            state.result.metadata.originalFileName,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 48),
          FilledButton.icon(
            onPressed: () {
              ref.read(archiveProvider.notifier).reset();
              context.go('/');
            },
            icon: const Icon(Icons.home),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, ArchiveError state) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 24),
          Text(
            'Error',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(
            state.message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (state.canRetry)
            FilledButton(
              onPressed: () {
                context.go('/archive/settings');
              },
              child: const Text('Try Again'),
            ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              ref.read(archiveProvider.notifier).reset();
              context.go('/');
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _startWriting(
    BuildContext context,
    WidgetRef ref,
    ArchiveReady state,
  ) async {
    ref.read(archiveProvider.notifier).startWriting();
    await ref.read(nfcSessionProvider.notifier).startWriteSession(
          chunk: state.currentChunk,
          message: 'Hold tag near device to write chunk '
              '${state.currentChunkIndex + 1} of ${state.totalChunks}',
        );
  }

  Future<void> _showCancelDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Archive?'),
        content: const Text(
          'Progress will be lost. Are you sure you want to cancel?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Continue'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      ref.read(archiveProvider.notifier).reset();
      ref.read(nfcSessionProvider.notifier).stopSession();
      context.go('/');
    }
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.current,
    required this.total,
    required this.progress,
  });

  final int current;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Progress',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '$current / $total tags',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${(progress * 100).toInt()}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
