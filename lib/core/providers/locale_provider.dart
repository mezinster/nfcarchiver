import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key for storing locale preference in SharedPreferences.
const _localeKey = 'app_locale';

/// Supported locales in the app.
const supportedLocales = [
  Locale('en'), // English
  Locale('ru'), // Russian
  Locale('tr'), // Turkish
  Locale('uk'), // Ukrainian
  Locale('ka'), // Georgian
];

/// Provider for SharedPreferences instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in main');
});

/// Notifier for managing app locale with persistence.
class LocaleNotifier extends StateNotifier<Locale?> {
  LocaleNotifier(this._prefs) : super(null) {
    _loadLocale();
  }

  final SharedPreferences _prefs;

  void _loadLocale() {
    final savedLocale = _prefs.getString(_localeKey);
    if (savedLocale != null) {
      state = Locale(savedLocale);
    }
    // If null, the app will use system locale
  }

  /// Set the app locale and persist it.
  Future<void> setLocale(Locale locale) async {
    state = locale;
    await _prefs.setString(_localeKey, locale.languageCode);
  }

  /// Clear the locale preference (use system default).
  Future<void> clearLocale() async {
    state = null;
    await _prefs.remove(_localeKey);
  }
}

/// Provider for the current locale.
/// Returns null to use system locale, or a specific Locale.
final localeProvider = StateNotifierProvider<LocaleNotifier, Locale?>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return LocaleNotifier(prefs);
});

/// Get the effective locale (either user-selected or system default).
Locale getEffectiveLocale(Locale? userLocale) {
  if (userLocale != null) {
    return userLocale;
  }
  // Get system locale
  final systemLocale = PlatformDispatcher.instance.locale;
  // Check if system locale is supported
  for (final locale in supportedLocales) {
    if (locale.languageCode == systemLocale.languageCode) {
      return locale;
    }
  }
  // Default to English
  return const Locale('en');
}
