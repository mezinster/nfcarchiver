import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards iOS project settings that only fail at App Store upload or review —
/// long after a green `flutter test`, and on a Mac nobody may have to hand.
void main() {
  final entitlements =
      File('ios/Runner/Runner.entitlements').readAsStringSync();
  final pbxproj =
      File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
  final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

  group('NFC entitlement', () {
    String formats() {
      final match = RegExp(
        r'<key>com\.apple\.developer\.nfc\.readersession\.formats</key>\s*'
        r'<array>(.*?)</array>',
        dotAll: true,
      ).firstMatch(entitlements);
      expect(match, isNotNull, reason: 'NFC formats entitlement missing');
      return match!.group(1)!;
    }

    test('requests TAG, which nfc_manager\'s NFCTagReaderSession needs', () {
      expect(formats(), contains('<string>TAG</string>'));
    });

    // Development signing accepts NDEF; App Store upload rejects it
    // (ITMS-90778 "NDEF is disallowed"). TAG already covers NDEF tags.
    test('does not request NDEF, which App Store upload rejects', () {
      expect(formats(), isNot(contains('<string>NDEF</string>')));
    });
  });

  group('iPhone only', () {
    // iPads have no NFC radio; shipping for iPad also demands iPad screenshots.
    test('every TARGETED_DEVICE_FAMILY is iPhone (1)', () {
      final families = RegExp(r'TARGETED_DEVICE_FAMILY = ([^;]+);')
          .allMatches(pbxproj)
          .map((m) => m.group(1)!.replaceAll('"', ''))
          .toList();
      expect(families, isNotEmpty);
      expect(families, everyElement('1'));
    });

    test('Info.plist carries no iPad-specific orientations', () {
      expect(infoPlist, isNot(contains('UISupportedInterfaceOrientations~ipad')));
    });
  });

  group('privacy manifest', () {
    test('exists and declares no tracking', () {
      final manifest =
          File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
      expect(
        RegExp(r'<key>NSPrivacyTracking</key>\s*<false/>').hasMatch(manifest),
        isTrue,
      );
    });

    // A file on disk that is not in the Resources build phase never reaches
    // the bundle, and App Store Connect reports the manifest as missing.
    test('is copied into the app bundle by the Resources build phase', () {
      expect(pbxproj, contains('/* PrivacyInfo.xcprivacy in Resources */,'));
    });
  });
}
