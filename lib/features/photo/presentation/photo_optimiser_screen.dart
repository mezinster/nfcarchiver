import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import '../../../core/log/logger.dart';
import '../../../core/providers/dev_options_provider.dart';
import '../../../shared/utils/format_utils.dart';
import '../../../shared/widgets/repeat_button.dart';
import '../../diagnostics/presentation/diagnostics_screen.dart';
import '../../nfc/domain/tag_type_availability.dart';
import '../../nfc/presentation/providers/reader_provider.dart';
import '../domain/photo_fit.dart';
import 'photo_optimiser_provider.dart';

/// Shrinks a photo to fit a chosen number of tags before archiving it.
class PhotoOptimiserScreen extends ConsumerWidget {
  const PhotoOptimiserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final photo = ref.read(pendingPhotoProvider);
    if (photo == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.optimisePhotoTitle)),
        body: Center(child: Text(l10n.noFileSelected)),
      );
    }

    final st = ref.watch(photoOptimiserProvider);
    final notifier = ref.read(photoOptimiserProvider.notifier);
    // Asked of the active reader, as on Archive settings.
    final mifareAvailable =
        ref.watch(mifareClassicAvailableProvider).valueOrNull ?? false;
    final mifare4kEnabled = ref.watch(mifare4kEnabledProvider);
    final theme = Theme.of(context);
    final failed = st.error != PhotoError.none;
    final result = st.result;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.optimisePhotoTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/archive'),
        ),
      ),
      // Pinned outside the scroll view: at phone width and large text a Row
      // of Skip and Continue overflowed and clipped Continue off-screen.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed:
                    st.canContinue ? () => _continue(context, ref) : null,
                child: Text(l10n.photoContinue, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  notifier.skip();
                  context.go('/archive/settings');
                },
                child: Text(l10n.photoSkip, textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Preview(state: st, originalSize: photo.size),
          const SizedBox(height: 8),
          SizedBox(
            height: 4,
            child: st.busy && !failed ? const LinearProgressIndicator() : null,
          ),
          const SizedBox(height: 16),
          if (failed)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.photoCannotRead,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            )
          else ...[
            Text(l10n.writingTo, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in selectableTagTypes(
                    mifareAvailable: mifareAvailable,
                    mifare4kEnabled: mifare4kEnabled))
                  ChoiceChip(
                    label: Text(type.name),
                    selected: type == st.tagType,
                    onSelected: (_) => notifier.setTagType(type),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.tagsToUse, style: theme.textTheme.titleSmall),
            Row(
              children: [
                RepeatButton(
                  icon: Icons.remove,
                  semanticLabel: l10n.photoFewerTags,
                  step: -1,
                  // Read at step time: two taps in one frame must both count.
                  onStep: (d) => notifier
                      .setTags(ref.read(photoOptimiserProvider).tags + d),
                  onHoldStart: notifier.beginHold,
                  onHoldEnd: notifier.endHold,
                ),
                Semantics(
                  button: true,
                  hint: l10n.photoEditTagCount,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _typeCount(context, ref),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Text('${st.tags}',
                          key: const Key('photoTagCount'),
                          style: theme.textTheme.titleLarge),
                    ),
                  ),
                ),
                RepeatButton(
                  icon: Icons.add,
                  semanticLabel: l10n.photoMoreTags,
                  step: 1,
                  onStep: (d) => notifier
                      .setTags(ref.read(photoOptimiserProvider).tags + d),
                  onHoldStart: notifier.beginHold,
                  onHoldEnd: notifier.endHold,
                ),
              ],
            ),
            if (result != null && !result.fits)
              Text(
                l10n.photoDoesNotFit(st.tags, st.needed ?? st.tags),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (result != null && st.mode == PhotoMode.auto)
              Text(l10n.photoBestFit(result.maxSide, result.quality)),
            const SizedBox(height: 16),
            if (st.longestSide > 0) _ManualControls(state: st),
          ],
        ],
      ),
    );
  }

  /// Asks for the tag count; clamped to [1, cap], empty or invalid input
  /// changes nothing.
  Future<void> _typeCount(BuildContext context, WidgetRef ref) async {
    final st = ref.read(photoOptimiserProvider);
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _TagCountDialog(initial: st.tags, cap: st.cap),
    );
    if (n == null || !context.mounted) return;
    final cap = ref.read(photoOptimiserProvider).cap;
    ref.read(photoOptimiserProvider.notifier).setTags(n.clamp(1, cap));
  }

  Future<void> _continue(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(photoOptimiserProvider.notifier).continueWithResult();
      if (context.mounted) context.go('/archive/settings');
    } catch (e, st) {
      log.report('photo', 'saving the optimised photo failed', e, st);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.somethingWentWrong),
            action: SnackBarAction(
              label: l10n.details,
              onPressed: () => context.push(diagnosticsRoute),
            ),
          ),
        );
      }
    }
  }
}

/// Asks for the tag count. Pops the typed number, or null for Cancel and for
/// empty input; the caller clamps it.
class _TagCountDialog extends StatefulWidget {
  const _TagCountDialog({required this.initial, required this.cap});

  final int initial;
  final int cap;

  @override
  State<_TagCountDialog> createState() => _TagCountDialogState();
}

class _TagCountDialogState extends State<_TagCountDialog> {
  // Owned by the dialog: disposing it when showDialog's future completes
  // would pull it from under the exit animation.
  late final _controller = TextEditingController(text: '${widget.initial}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(int.tryParse(_controller.text));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.tagsToUse),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(helperText: '1–${widget.cap}'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(l10n.ok)),
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.state, required this.originalSize});

  final PhotoOptimiserState state;

  /// The original file's byte length.
  final int originalSize;

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    return Column(
      children: [
        SizedBox(
          height: 240,
          child: result == null
              ? Center(
                  child: Icon(Icons.image_outlined,
                      size: 64, color: Theme.of(context).disabledColor),
                )
              : Image.memory(
                  result.bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(Icons.broken_image, size: 64)),
                ),
        ),
        if (result != null) ...[
          const SizedBox(height: 8),
          Text(_label(result), style: Theme.of(context).textTheme.bodyMedium),
          if (result.bytes.length >= originalSize) ...[
            const SizedBox(height: 4),
            Text(
              AppLocalizations.of(context)!.photoLargerThanOriginal,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ],
    );
  }

  String _label(PhotoFitResult r) {
    final longest = state.longestSide;
    int scaled(int v) =>
        r.maxSide >= longest ? v : (v * r.maxSide / longest).round();
    return '${scaled(state.width)}×${scaled(state.height)} · '
        'q${r.quality} · ${formatFileSize(r.bytes.length)}';
  }
}

class _ManualControls extends ConsumerWidget {
  const _ManualControls({required this.state});

  final PhotoOptimiserState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(photoOptimiserProvider.notifier);
    final manual = state.mode == PhotoMode.manual;
    final side = manual ? state.manualSide : state.result?.maxSide;
    final quality =
        (manual ? state.manualQuality : state.result?.quality) ?? 70;
    final sides = candidateSides(state.longestSide);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.photoManual, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in sides)
              ChoiceChip(
                label: Text(s == sides.first ? l10n.photoOriginalSize : '$s'),
                selected: s == side,
                onSelected: (_) => notifier.setManual(side: s),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(l10n.photoQuality(quality)),
        Slider(
          min: 1,
          max: 100,
          divisions: 99,
          value: quality.clamp(1, 100).toDouble(),
          label: '$quality',
          onChanged: (v) => notifier.setManual(quality: v.round()),
        ),
        if (manual)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: notifier.backToAuto,
              child: Text(l10n.photoBackToAuto),
            ),
          ),
      ],
    );
  }
}
