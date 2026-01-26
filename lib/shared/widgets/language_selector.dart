import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/locale_provider.dart';

/// Language selector widget with flag icons.
class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);
    final effectiveLocale = getEffectiveLocale(currentLocale);

    return PopupMenuButton<Locale>(
      icon: Text(
        _getFlagEmoji(effectiveLocale.languageCode),
        style: const TextStyle(fontSize: 24),
      ),
      tooltip: AppLocalizations.of(context)?.language ?? 'Language',
      onSelected: (locale) {
        ref.read(localeProvider.notifier).setLocale(locale);
      },
      itemBuilder: (context) => [
        _buildMenuItem(
          context,
          const Locale('en'),
          effectiveLocale,
        ),
        _buildMenuItem(
          context,
          const Locale('ru'),
          effectiveLocale,
        ),
      ],
    );
  }

  PopupMenuItem<Locale> _buildMenuItem(
    BuildContext context,
    Locale locale,
    Locale currentLocale,
  ) {
    final isSelected = locale.languageCode == currentLocale.languageCode;
    final l10n = AppLocalizations.of(context);

    return PopupMenuItem<Locale>(
      value: locale,
      child: Row(
        children: [
          Text(
            _getFlagEmoji(locale.languageCode),
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(width: 12),
          Text(_getLanguageName(locale.languageCode, l10n)),
          if (isSelected) ...[
            const Spacer(),
            Icon(
              Icons.check,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ],
      ),
    );
  }

  String _getFlagEmoji(String languageCode) {
    switch (languageCode) {
      case 'ru':
        return '\u{1F1F7}\u{1F1FA}'; // Russian flag
      case 'en':
      default:
        return '\u{1F1FA}\u{1F1F8}'; // US flag
    }
  }

  String _getLanguageName(String languageCode, AppLocalizations? l10n) {
    switch (languageCode) {
      case 'ru':
        return l10n?.russian ?? 'Russian';
      case 'en':
      default:
        return l10n?.english ?? 'English';
    }
  }
}
