import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/log/logger.dart';
import '../../l10n/app_localizations.dart';
import '../archive/domain/archive_intake.dart';
import '../archive/presentation/providers/archive_provider.dart';
import '../photo/data/photo_temp.dart';
import '../photo/presentation/photo_optimiser_provider.dart';
import '../restore/presentation/providers/restore_provider.dart';
import 'share_inbox.dart';

/// Takes items shared into the app and routes them into the archive flow.
///
/// Sits in `MaterialApp.router`'s `builder`, i.e. above the Navigator, so it
/// navigates through [router] and shows dialogs and snackbars with the
/// router's navigator context.
///
/// Asks the inbox after the first frame (cold start), on every resume (iOS,
/// whose extension cannot wake the app) and on `onShareAvailable` (Android
/// `onNewIntent`), one `take()` at a time.
class ShareInListener extends ConsumerStatefulWidget {
  const ShareInListener({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ShareInListener> createState() => _ShareInListenerState();
}

class _ShareInListenerState extends ConsumerState<ShareInListener>
    with WidgetsBindingObserver {
  late final ShareInbox _inbox;
  bool _taking = false;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    _inbox = ref.read(shareInboxProvider);
    WidgetsBinding.instance.addObserver(this);
    _inbox.listen(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inbox.stopListening();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  BuildContext? get _navContext =>
      widget.router.routerDelegate.navigatorKey.currentContext;

  Future<void> _check() async {
    if (!mounted) return;
    if (_taking) {
      // Honoured once the current take is done, so a share arriving now
      // isn't left until the next resume.
      _again = true;
      return;
    }
    _taking = true;
    try {
      do {
        _again = false;
        await _takeOne();
      } while (_again && mounted);
    } finally {
      _taking = false;
    }
  }

  Future<void> _takeOne() async {
    SharedItem? item;
    try {
      item = await _inbox.take();
    } on PlatformException catch (e, st) {
      log.report('share', 'share take failed', e, st, {'code': e.code});
      _snack((l10n) => e.code == shareUnreadableCode
          ? l10n.shareCouldNotRead
          : l10n.somethingWentWrong);
      return;
    } catch (e, st) {
      log.report('share', 'share take failed', e, st);
      _snack((l10n) => l10n.somethingWentWrong);
      return;
    }
    if (item == null) return;
    if (!mounted) {
      _discard(item);
      return;
    }
    try {
      await _route(item);
    } catch (e, st) {
      log.report('share', 'share routing failed', e, st);
      _discard(item);
      _snack((l10n) => l10n.somethingWentWrong);
    }
  }

  Future<void> _route(SharedItem item) async {
    final archive = ref.read(archiveProvider);
    final restore = ref.read(restoreProvider);
    final archiveBusy = archiveWorkInProgress(archive);
    final restoreBusy = restoreWorkInProgress(restore);
    log.info('share', 'shared item received', {
      'image': item.isImage,
      'count': item.count,
      'archiveBusy': archiveBusy,
      'restoreBusy': restoreBusy,
    });

    if (archiveBusy || restoreBusy) {
      final confirmed = await _confirmDiscard(archiveBusy: archiveBusy);
      if (!mounted || !confirmed) {
        _discard(item);
        return;
      }
      if (archiveBusy) ref.read(archiveProvider.notifier).reset();
      if (restoreBusy) ref.read(restoreProvider.notifier).reset();
    }

    // Sync on purpose: one stat, and it keeps the routing in one frame.
    final size = File(item.path).lengthSync();

    // Never let the destination show leftovers of an earlier pick.
    if (item.isImage) {
      if (ref.read(archiveProvider) is! ArchiveInitial) {
        ref.read(archiveProvider.notifier).reset();
      }
    } else {
      ref.read(pendingPhotoProvider.notifier).state = null;
    }

    final route = intakeFile(ref,
        path: item.path, name: item.name, size: size, isImage: item.isImage);
    if (route == IntakeRoute.optimise) {
      // The optimiser reads the pending photo once; a share arriving while it
      // is already open must start it over.
      ref.invalidate(photoOptimiserProvider);
    }
    widget.router.go(switch (route) {
      IntakeRoute.optimise => '/archive/optimise',
      IntakeRoute.settings => '/archive/settings',
    });

    if (item.count > 1) {
      _snack((l10n) => l10n.shareOnlyFirst(item.count));
    }
  }

  Future<bool> _confirmDiscard({required bool archiveBusy}) async {
    final context = _navContext;
    if (context == null) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(l10n.shareDiscardTitle),
          // Written tags are the bigger loss, so they win when both are busy.
          content: Text(archiveBusy
              ? l10n.shareDiscardBody
              : l10n.shareDiscardRestoreBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.shareDiscardConfirm),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  void _snack(String Function(AppLocalizations l10n) text) {
    final context = _navContext;
    if (!mounted || context == null) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text(l10n))));
  }

  /// Deletes a refused item's copy, and its `share_in/<uuid>` folder once
  /// empty. Never anything outside a `share_in` folder.
  void _discard(SharedItem item) {
    try {
      final file = File(item.path);
      if (file.existsSync()) file.deleteSync();
      final dir = file.parent;
      if (p.basename(dir.parent.path) == shareInDirName &&
          dir.existsSync() &&
          dir.listSync().isEmpty) {
        dir.deleteSync();
      }
    } catch (e) {
      // The type alone: a FileSystemException's text carries a path. The
      // next launch's temp cleanup gets whatever is left.
      log.warn('share', 'discarding shared copy failed',
          {'error': '${e.runtimeType}'});
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
