import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:nfc_archiver/shared/privacy_policy_url.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] outside the app. Returns whether it was launched.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _launchExternally(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// A short privacy summary plus a link to the full policy on the website.
///
/// The URL stays visible and selectable so the policy is reachable even when
/// the phone has no browser to launch.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key, UrlOpener? openUrl})
      : _openUrl = openUrl ?? _launchExternally;

  final UrlOpener _openUrl;

  Future<void> _open(BuildContext context, Uri url) async {
    final messenger = ScaffoldMessenger.of(context);
    final message =
        AppLocalizations.of(context)!.privacyPolicyOpenFailed(url.toString());
    var opened = false;
    try {
      opened = await _openUrl(url);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final url = privacyPolicyUrl(Localizations.localeOf(context));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.privacyPolicyTitle),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.privacyPolicyContent,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _open(context, url),
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.privacyPolicyOpenFull),
            ),
            const SizedBox(height: 12),
            SelectableText(
              url.toString(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
