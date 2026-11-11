import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'locale_provider.dart';

const _unlockedKey = 'dev.unlocked';
const _mifare4kKey = 'dev.mifare4k';

/// Hidden developer settings. Everything defaults to off.
class DevOptions {
  const DevOptions({this.unlocked = false, this.mifare4k = false});

  /// The options screen has been revealed (seven taps on the version footer).
  final bool unlocked;

  /// Writing to Mifare Classic 4K is offered. Experimental until verified on
  /// a real card; reading and inspecting 4K are never gated by this.
  final bool mifare4k;

  DevOptions copyWith({bool? unlocked, bool? mifare4k}) => DevOptions(
        unlocked: unlocked ?? this.unlocked,
        mifare4k: mifare4k ?? this.mifare4k,
      );
}

class DevOptionsNotifier extends StateNotifier<DevOptions> {
  DevOptionsNotifier(this._prefs)
      : super(DevOptions(
          unlocked: _prefs.getBool(_unlockedKey) ?? false,
          mifare4k: _prefs.getBool(_mifare4kKey) ?? false,
        ));

  final SharedPreferences _prefs;

  Future<void> unlock() async {
    state = state.copyWith(unlocked: true);
    await _prefs.setBool(_unlockedKey, true);
  }

  Future<void> setMifare4k(bool on) async {
    state = state.copyWith(mifare4k: on);
    await _prefs.setBool(_mifare4kKey, on);
  }
}

final devOptionsProvider =
    StateNotifierProvider<DevOptionsNotifier, DevOptions>((ref) {
  return DevOptionsNotifier(ref.watch(sharedPreferencesProvider));
});

/// Whether Mifare Classic 4K may be written.
final mifare4kEnabledProvider =
    Provider<bool>((ref) => ref.watch(devOptionsProvider).mifare4k);
