import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import '../../core/services/file_actions_service.dart';

/// Snackbar feedback shared by every screen that offers Open / Save to device.
///
/// A successful open says nothing: the viewer app coming to the foreground is
/// the feedback.
Future<void> openWithFeedback(
  BuildContext context,
  Future<OpenOutcome> Function() open,
) async {
  final outcome = await open();
  if (!context.mounted || outcome == OpenOutcome.opened) return;
  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        outcome == OpenOutcome.noApp ? l10n.noAppToOpen : l10n.openFailed,
      ),
    ),
  );
}

/// A dismissed picker says nothing; only a real save is confirmed.
Future<void> exportWithFeedback(
  BuildContext context,
  Future<bool> Function() export,
) async {
  final saved = await export();
  if (!context.mounted || !saved) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context)!.savedToDevice)),
  );
}
