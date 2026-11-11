import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import '../../../core/providers/dev_options_provider.dart';

/// Where the About dialog's "Developer options" button leads.
const devOptionsRoute = '/developer-options';

/// Experimental switches, revealed by tapping the version footer.
class DevOptionsScreen extends ConsumerWidget {
  const DevOptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final options = ref.watch(devOptionsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.developerOptions)),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(l10n.mifare4kToggle),
            subtitle: Text(l10n.mifare4kToggleSubtitle),
            value: options.mifare4k,
            onChanged: (on) =>
                ref.read(devOptionsProvider.notifier).setMifare4k(on),
          ),
        ],
      ),
    );
  }
}
