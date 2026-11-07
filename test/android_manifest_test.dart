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

  test('declares package visibility for opening an https link in a browser',
      () {
    final intent = RegExp(
      '<intent>\\s*<action android:name="android.intent.action.VIEW"\\s*/>'
      '\\s*<data android:scheme="https"\\s*/>\\s*</intent>',
    );
    expect(intent.hasMatch(queries()), isTrue);
  });

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

  // RxAndroidBle declares both with no maxSdkVersion; without this cap the
  // merger ships them to Android 12+, where nothing needs them (issue #104).
  for (final permission in ['ACCESS_COARSE_LOCATION', 'ACCESS_FINE_LOCATION']) {
    test('caps $permission at Android 11 over the library declaration', () {
      final cap = RegExp(
        '<uses-permission-sdk-23\\s+android:name="android.permission.$permission"'
        '\\s+android:maxSdkVersion="30"\\s+tools:node="replace"\\s*/>',
      );
      expect(cap.hasMatch(manifest), isTrue);
    });
  }
}
