import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the manifest entries that Open / Save to device / Share depend on.
/// Nothing in Dart fails when one goes missing — the chooser just comes up
/// nearly empty on Android 11+, or the merged APK quietly gains permissions.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  String queries() {
    final match =
        RegExp(r'<queries>(.*?)</queries>', dotAll: true).firstMatch(manifest);
    expect(match, isNotNull, reason: 'no <queries> block');
    return match!.group(1)!;
  }

  for (final action in ['SEND', 'SEND_MULTIPLE', 'VIEW']) {
    test('declares package visibility for ACTION_$action on any MIME type', () {
      final intent = RegExp(
        '<intent>\\s*<action android:name="android.intent.action.$action"\\s*/>'
        '\\s*<data android:mimeType="\\*/\\*"\\s*/>\\s*</intent>',
      );
      expect(intent.hasMatch(queries()), isTrue);
    });
  }

  for (final permission in [
    'READ_MEDIA_IMAGES',
    'READ_MEDIA_VIDEO',
    'READ_MEDIA_AUDIO',
  ]) {
    test('strips $permission merged in by open_filex', () {
      final removal = RegExp(
        '<uses-permission\\s+android:name="android.permission.$permission"'
        '\\s+tools:node="remove"\\s*/>',
      );
      expect(removal.hasMatch(manifest), isTrue);
    });
  }
}
