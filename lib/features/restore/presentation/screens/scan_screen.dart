import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../nfc/nfc.dart';
import '../providers/restore_provider.dart';

/// Screen for scanning NFC tags to restore an archive.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  @override
  void initState() {
    super.initState();
    _startScanning();
  }

  void _startScanning() {
    ref.read(restoreProvider.notifier).startScanning();
    _startNfcSession();
  }

  Future<void> _startNfcSession() async {
    final nfcAvailable = await ref.read(nfcAvailableProvider.future);
    if (!nfcAvailable) {
      ref.read(restoreProvider.notifier).scanError('NFC is not available');
      return;
    }

    ref.read(nfcSessionProvider.notifier).startReadSession(
          message: 'Hold your device near an NFC tag',
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(restoreProvider);
    final nfcState = ref.watch(nfcSessionProvider);

    // Listen to NFC session changes
    ref.listen(nfcSessionProvider, (previous, next) {
      if (next is NfcSessionReadSuccess) {
        // Parse chunk and process
        try {
          final chunk = next.chunk;
          ref.read(restoreProvider.notifier).processChunk(chunk);
        } catch (e) {
          ref.read(restoreProvider.notifier).scanError(e.toString());
        }

        // Continue scanning
        _startNfcSession();
      } else if (next is NfcSessionError) {
        ref.read(restoreProvider.notifier).scanError(next.message);
        // Continue scanning despite error
        _startNfcSession();
      }
    });

    // Navigate when ready
    ref.listen(restoreProvider, (previous, next) {
      if (next is RestoreReady) {
        context.go('/restore/complete');
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Tags'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            ref.read(nfcSessionProvider.notifier).stopSession();
            ref.read(restoreProvider.notifier).reset();
            context.go('/');
          },
        ),
      ),
      body: _buildBody(context, state, nfcState),
    );
  }

  Widget _buildBody(
    BuildContext context,
    RestoreState state,
    NfcSessionState nfcState,
  ) {
    if (state is RestoreScanning) {
      return _buildScanningView(context, state, nfcState);
    }

    if (state is RestoreError) {
      return _buildErrorView(context, state);
    }

    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildScanningView(
    BuildContext context,
    RestoreScanning state,
    NfcSessionState nfcState,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // NFC Animation/Status
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _NfcAnimatedIcon(isScanning: nfcState is NfcSessionWaiting),
                  const SizedBox(height: 24),
                  Text(
                    nfcState is NfcSessionWaiting
                        ? 'Scanning for tags...'
                        : 'Preparing scanner...',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Hold each NFC tag near your device',
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
          ),

          // Last scanned info
          if (state.lastScannedChunk != null) ...[
            Card(
              color: state.lastScannedChunk!.isNew
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      state.lastScannedChunk!.isNew
                          ? Icons.check_circle
                          : Icons.info,
                      color: state.lastScannedChunk!.isNew
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.lastScannedChunk!.isNew
                                ? 'New chunk found!'
                                : 'Duplicate chunk',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            'Chunk ${state.lastScannedChunk!.chunkIndex + 1} '
                            'of ${state.lastScannedChunk!.totalChunks}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Error message
          if (state.lastError != null) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        state.lastError!,
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Sessions list
          if (state.sessions.isNotEmpty) ...[
            Text(
              'Archives in progress',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...state.sessions.map(
              (session) => _SessionCard(session: session),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, RestoreError state) {
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
              onPressed: _startScanning,
              child: const Text('Try Again'),
            ),
        ],
      ),
    );
  }
}

class _NfcAnimatedIcon extends StatefulWidget {
  const _NfcAnimatedIcon({required this.isScanning});

  final bool isScanning;

  @override
  State<_NfcAnimatedIcon> createState() => _NfcAnimatedIconState();
}

class _NfcAnimatedIconState extends State<_NfcAnimatedIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isScanning) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_NfcAnimatedIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isScanning && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.scale(
          scale: widget.isScanning ? _animation.value : 1.0,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withOpacity(0.3),
            ),
            child: Icon(
              Icons.nfc,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});

  final RestoreSessionInfo session;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  session.isComplete ? Icons.check_circle : Icons.pending,
                  color: session.isComplete
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Archive ${session.archiveId.substring(0, 8)}...',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (session.isEncrypted)
                  Icon(
                    Icons.lock,
                    size: 16,
                    color: Theme.of(context).colorScheme.outline,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: session.progress,
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${session.receivedCount}/${session.totalChunks}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
