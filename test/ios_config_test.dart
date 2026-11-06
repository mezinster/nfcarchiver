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

  group('signing team', () {
    const teamLine = 'DEVELOPMENT_TEAM = C6LYTC662B';
    const overrideInclude = '#include? "LocalOverrides.xcconfig"';

    // Target-level build settings beat xcconfig values, so a team Xcode
    // writes into the target would silently override LocalOverrides.xcconfig
    // for a free-team developer.
    test('project.pbxproj sets no DEVELOPMENT_TEAM', () {
      expect(pbxproj, isNot(contains('DEVELOPMENT_TEAM')));
    });

    for (final config in ['Debug', 'Profile', 'Release']) {
      test('$config.xcconfig sets the paid team', () {
        final xcconfig =
            File('ios/Flutter/$config.xcconfig').readAsStringSync();
        expect(xcconfig, contains(teamLine));
        // Where there is an override hook, the team must come before it, or a
        // free-team developer could no longer substitute their own.
        final hook = xcconfig.indexOf(overrideInclude);
        if (hook != -1) {
          expect(xcconfig.indexOf(teamLine), lessThan(hook));
        }
      });
    }
  });

  group('bundle ID', () {
    // com.nfcarchiver.nfcArchiver is registered to an unrelated team, so the
    // store app is com.nfcarchiver.app. After the first upload it can never
    // change: a different bundle ID is a different app.
    const bundleId = 'com.nfcarchiver.app';

    for (final config in ['Debug', 'Profile', 'Release']) {
      test('$config.xcconfig uses $bundleId', () {
        final xcconfig =
            File('ios/Flutter/$config.xcconfig').readAsStringSync();
        expect(xcconfig, contains('NFAR_BUNDLE_ID = $bundleId\n'));
      });
    }

    test('RunnerTests IDs and ExportOptions follow it', () {
      expect(pbxproj, isNot(contains('com.nfcarchiver.nfcArchiver')));
      expect(pbxproj, contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId.RunnerTests;'));
      final exportOptions =
          File('ios/ExportOptions.plist').readAsStringSync();
      expect(exportOptions, contains('<key>$bundleId</key>'));
      expect(exportOptions, contains('<string>C6LYTC662B</string>'));
    });
  });

  group('deployment target', () {
    // file_picker's Swift package (file-picker-darwin) requires iOS 14.0;
    // at 13.0 xcodebuild fails resolving FlutterGeneratedPluginSwiftPackage.
    test('every IPHONEOS_DEPLOYMENT_TARGET is at least 14.0', () {
      final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);')
          .allMatches(pbxproj)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      expect(targets, isNotEmpty);
      expect(targets, everyElement(greaterThanOrEqualTo(14.0)));
    });
  });

  group('export compliance', () {
    // The app ships its own AES-256-GCM (pointycastle): standard algorithms,
    // not exempt, declared under the mass-market exemption. Without the key
    // every upload stops at the compliance question in App Store Connect.
    test('Info.plist declares non-exempt encryption', () {
      expect(
        RegExp(r'<key>ITSAppUsesNonExemptEncryption</key>\s*<true/>')
            .hasMatch(infoPlist),
        isTrue,
      );
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
