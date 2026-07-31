import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/chameleon/chameleon_device.dart';
import '../../data/report_share.dart';
import '../../domain/inspect_sink.dart';
import '../providers/inspect_provider.dart';

/// Read-only dump of the presented card: identity, decoded NFAR header with
/// CRC verification, and raw hex/ASCII per block or page.
///
/// Never writes. Sector trailers are displayed, never modified.
class InspectDialog extends ConsumerStatefulWidget {
  const InspectDialog({super.key, required this.device, this.uid = 'card'});

  final ChameleonDevice device;

  /// Used in the shared filename so two dumps do not collide.
  final String uid;

  @override
  ConsumerState<InspectDialog> createState() => _InspectDialogState();
}

class _InspectDialogState extends ConsumerState<InspectDialog> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so AppLocalizations is available for the status
    // strings the run emits.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ref.read(inspectProvider.notifier).start(
            widget.device,
            strings: InspectStrings(
              holdStill: l10n.inspectHoldStill,
              done: l10n.inspectDone,
              stopped: l10n.inspectStopped,
              cardLost: l10n.inspectCardLost,
              reading: l10n.inspectReading,
              read: l10n.inspectRead,
            ),
          );
    });
  }

  void _close() {
    // Cancel BEFORE popping: a dialog dismissed mid-dump must not leave a run
    // polling the reader.
    ref.read(inspectProvider.notifier).cancel();
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _copy(String report, String confirmation) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(confirmation)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = ref.watch(inspectProvider);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurface,
    );

    return PopScope(
      canPop: false,
      // The hardware back button must take the same path as Close, or it
      // leaves the run alive behind a dismissed dialog.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.inspectTitle),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          actions: [
            IconButton(
              tooltip: l10n.inspectCopy,
              icon: const Icon(Icons.copy),
              onPressed: s.report == null
                  ? null
                  : () => _copy(s.report!, l10n.inspectCopied),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.isRunning) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                s.progress ?? s.status ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _Section(title: l10n.inspectIdentity, body: s.identity, style: mono),
                  _Section(title: l10n.inspectNfar, body: s.nfar, style: mono),
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 4),
                    child: Text(
                      l10n.inspectRaw,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  // Built lazily: 64 rows is fine, but the widget must not
                  // assume the list stays small.
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: s.rows.length,
                    itemBuilder: (_, i) => SelectableText(s.rows[i], style: mono),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: s.report == null
                          ? null
                          : () => _copy(s.report!, l10n.inspectCopied),
                      child: Text(l10n.inspectCopy),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: s.report == null
                          ? null
                          : () => shareReport(s.report!, uid: widget.uid),
                      child: Text(l10n.inspectShare),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _close, child: Text(l10n.inspectClose)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body, required this.style});

  final String title;
  final String? body;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (body == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        // Selectable so a user can grab part of a dump without using Copy.
        SelectableText(body!, style: style),
      ],
    );
  }
}
