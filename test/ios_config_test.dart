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
    // App Store Connect refuses uploads targeting less than iOS 15.0 from
    // April 2027 (warned on every upload of 1.2.0). The earlier floor, 14.0,
    // came from file_picker's Swift package (file-picker-darwin).
    test('every IPHONEOS_DEPLOYMENT_TARGET is at least 15.0', () {
      final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);')
          .allMatches(pbxproj)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      expect(targets, isNotEmpty);
      expect(targets, everyElement(greaterThanOrEqualTo(15.0)));
    });
  });

  group('export compliance', () {
    // Declaring non-exempt encryption obliges the app to carry the code Apple
    // issues once its encryption documentation is approved. The first
    // TestFlight upload declared YES with no code and was rejected at
    // validation ("Invalid Export Compliance Code"). Until a code exists the
    // key stays out, and the questions are answered per build in App Store
    // Connect.
    test('non-exempt encryption is only declared together with its code', () {
      final declaresNonExempt =
          RegExp(r'<key>ITSAppUsesNonExemptEncryption</key>\s*<true/>')
              .hasMatch(infoPlist);
      if (declaresNonExempt) {
        expect(infoPlist, contains('<key>ITSEncryptionExportComplianceCode</key>'));
      }
    });
  });

  group('share extension', () {
    // The extension hands the shared file to the app through this App Group's
    // container. Both sides must name the same group, derived from the bundle
    // ID so a free-team override of NFAR_BUNDLE_ID keeps them matched.
    const appGroup = '<key>com.apple.security.application-groups</key>\n'
        '\t<array>\n'
        '\t\t<string>group.\$(NFAR_BUNDLE_ID)</string>\n'
        '\t</array>';

    String extensionFile(String name) =>
        File('ios/ShareExtension/$name').readAsStringSync();

    test('Runner and the extension both join the App Group', () {
      expect(entitlements, contains(appGroup));
      expect(extensionFile('ShareExtension.entitlements'), contains(appGroup));
    });

    // A bundle ID that is not a child of the app's is refused at signing, and
    // a literal one would break the free-team override of NFAR_BUNDLE_ID.
    test('bundle ID is derived from NFAR_BUNDLE_ID', () {
      expect(
        pbxproj,
        contains(
            'PRODUCT_BUNDLE_IDENTIFIER = "\$(NFAR_BUNDLE_ID).ShareExtension";'),
      );
      expect(pbxproj, isNot(contains('com.nfcarchiver.app.ShareExtension')));
    });

    test('has a target and is embedded in the app', () {
      expect(pbxproj, contains('/* ShareExtension.appex in Embed App Extensions */'));
      expect(pbxproj, contains('dstSubfolderSpec = 13;'));
    });

    // The deployment-target, device-family and signing-team groups above scan
    // every build configuration in project.pbxproj, so they already cover the
    // extension's. This pins that the extension really has its own
    // configurations for them to scan.
    test('every iOS configuration, the extension\'s included, is covered', () {
      final configs = RegExp(r'isa = XCBuildConfiguration;')
          .allMatches(pbxproj)
          .length;
      // Project (3) + Runner (3) + RunnerTests (3) + ShareExtension (3).
      expect(configs, 12);
      expect(
        RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = 15\.0;').allMatches(pbxproj).length,
        greaterThanOrEqualTo(6),
      );
    });

    test('activates on one or more images or files', () {
      final plist = extensionFile('Info.plist');
      expect(
        plist,
        contains('<key>NSExtensionPointIdentifier</key>\n'
            '\t\t<string>com.apple.share-services</string>'),
      );
      // A predicate rather than the *WithMaxCount keys: with a max count of 1,
      // selecting two photos hides the extension, but the spec wants a
      // multi-photo share accepted and its first item used.
      final rule = RegExp(
        r'<key>NSExtensionActivationRule</key>\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(plist);
      expect(rule, isNotNull, reason: 'activation rule must be a predicate');
      final predicate = rule!.group(1)!;
      expect(predicate, contains('SUBQUERY'));
      expect(predicate, contains('UTI-CONFORMS-TO &quot;public.image&quot;'));
      expect(predicate, contains('UTI-CONFORMS-TO &quot;public.file-url&quot;'));
      expect(predicate, contains('.@count &gt;= 1'));
    });

    // The extension picks the attachment to take with the same test the
    // activation rule applies, so a link + photo share takes the photo and
    // `count` counts only items it could have taken. Textual guard: the two
    // live in different languages.
    test('the attachment filter mirrors the activation rule', () {
      final predicate = RegExp(
        r'<key>NSExtensionActivationRule</key>\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(extensionFile('Info.plist'))!.group(1)!;
      const any = r'ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO ';
      expect(
        predicate,
        contains('$any&quot;public.image&quot; OR '
            '$any&quot;public.file-url&quot; OR '
            '($any&quot;public.data&quot; AND '
            'NOT ($any&quot;public.url&quot;) AND '
            'NOT ($any&quot;public.plain-text&quot;))'),
      );
      final swift = extensionFile('ShareViewController.swift');
      expect(
        swift,
        contains('return any(.image) || any(.fileURL)\n'
            '      || (any(.data) && !any(.url) && !any(.plainText))'),
      );
      expect(swift, contains('.filter(Self.qualifies)'));
    });

    // App Store validation rejects an extension whose versions differ from
    // the app's (ITMS-90473), so both read the same Flutter build settings.
    test('carries the app\'s version and build number', () {
      final plist = extensionFile('Info.plist');
      expect(plist, contains('<string>\$(FLUTTER_BUILD_NAME)</string>'));
      expect(plist, contains('<string>\$(FLUTTER_BUILD_NUMBER)</string>'));
    });

    // The app reads the inbox from the same container the extension writes,
    // so it names the group through the same Info.plist key and value.
    test('the app names the same App Group as the extension', () {
      final key = RegExp(r'<key>NFARAppGroup</key>\s*<string>(.*?)</string>');
      final app = key.firstMatch(infoPlist);
      final ext = key.firstMatch(extensionFile('Info.plist'));
      expect(app, isNotNull, reason: 'Runner Info.plist lacks NFARAppGroup');
      expect(ext, isNotNull);
      expect(app!.group(1), ext!.group(1));
      expect(app.group(1), r'group.$(NFAR_BUNDLE_ID)');
    });

    test('the app registers the URL scheme the extension opens', () {
      expect(infoPlist, contains('<string>nfcarchiver-share</string>'));
    });

    // Flutter enables deep linking by default: nfcarchiver-share://shared
    // would become a go_router route, racing the inbox take and navigating
    // away from a write or scan screen before the busy guard can ask. The app
    // has no deep links; the URL only wakes it.
    test('Flutter deep linking is off, so the share URL is not a route', () {
      expect(
        RegExp(r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>')
            .hasMatch(infoPlist),
        isTrue,
      );
    });

    // The paid team and the entitlements come in through the xcconfigs, the
    // same indirection as Runner's, so the free-team override can blank them.
    for (final config in ['Debug', 'Profile', 'Release']) {
      test('$config.xcconfig names the extension entitlements', () {
        final xcconfig =
            File('ios/Flutter/$config.xcconfig').readAsStringSync();
        const line = 'NFAR_SHARE_EXT_ENTITLEMENTS = '
            'ShareExtension/ShareExtension.entitlements';
        expect(xcconfig, contains(line));
        final hook = xcconfig.indexOf('#include? "LocalOverrides.xcconfig"');
        if (hook != -1) {
          expect(xcconfig.indexOf(line), lessThan(hook));
        }
      });
    }
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
