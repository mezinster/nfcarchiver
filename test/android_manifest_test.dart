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

  // Share-in: other apps hand the app one photo or file through the system
  // share sheet. These are the activity's own intent filters, not the
  // <queries> entries above, which are about sharing out.
  group('MainActivity', () {
    String activity() {
      final match = RegExp(
        r'<activity\s+android:name="\.MainActivity"(.*?)</activity>',
        dotAll: true,
      ).firstMatch(manifest);
      expect(match, isNotNull, reason: 'no .MainActivity');
      return match!.group(0)!;
    }

    List<String> filters() => RegExp(
          r'<intent-filter>(.*?)</intent-filter>',
          dotAll: true,
        ).allMatches(activity()).map((m) => m.group(1)!).toList();

    for (final action in ['SEND', 'SEND_MULTIPLE']) {
      test('receives ACTION_$action of images and any file', () {
        final filter = filters().where((f) => f.contains(
            '<action android:name="android.intent.action.$action"/>'));
        expect(filter, hasLength(1), reason: 'one $action filter');
        final body = filter.single;
        expect(
          body,
          contains('<category android:name="android.intent.category.DEFAULT"/>'),
        );
        expect(body, contains('<data android:mimeType="image/*"/>'));
        expect(body, contains('<data android:mimeType="*/*"/>'));
      });
    }

    // singleTask: a share from another app's chooser reaches the one
    // running instance through onNewIntent. singleTop let the chooser start a
    // second activity + engine in the sender's task, whose startup cleared
    // the first instance's temp files and whose busy guard could not see it.
    test('uses launchMode singleTask with an empty taskAffinity', () {
      expect(activity(), contains('android:launchMode="singleTask"'));
      expect(activity(), isNot(contains('android:launchMode="singleTop"')));
      expect(activity(), contains('android:taskAffinity=""'));
    });

    test('keeps the NDEF_DISCOVERED filter for archive chunks', () {
      final ndef = filters().where((f) => f.contains(
          '<action android:name="android.nfc.action.NDEF_DISCOVERED"/>'));
      expect(ndef, hasLength(1));
      expect(
        ndef.single,
        contains('<data android:mimeType="application/vnd.nfcarchiver.chunk"/>'),
      );
    });
  });

  // Shared content arrives as a content:// URI with a one-off read grant, so
  // receiving it needs no media permission.
  test('requests no READ_MEDIA_* permission', () {
    final requests = RegExp(
      r'<uses-permission\s+android:name="android\.permission\.READ_MEDIA_\w+"'
      r'(?![^>]*tools:node="remove")[^>]*/>',
    );
    expect(requests.hasMatch(manifest), isFalse);
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
