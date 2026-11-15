import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';

/// The native share-in code refuses items above the largest possible archive
/// before copying them. It cannot import Dart constants, so each side carries
/// the number as `65_535 * 3_408`; this holds all three to the format.
void main() {
  final largestArchive = NfarLimits.maxChunks *
      NfcTagType.values.map((t) => t.maxPayloadSize).reduce((a, b) => a > b ? a : b);

  int capIn(String path, RegExp declaration) {
    final m = declaration.firstMatch(File(path).readAsStringSync());
    expect(m, isNotNull, reason: 'no size cap found in $path');
    return int.parse(m!.group(1)!.replaceAll('_', '')) *
        int.parse(m.group(2)!.replaceAll('_', ''));
  }

  test('the largest archive is 65,535 Mifare Classic 4K payloads', () {
    expect(largestArchive, 65535 * 3408);
  });

  test('Android refuses shares above the largest archive', () {
    expect(
      capIn(
          'android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/ShareInbox.kt',
          RegExp(r'const val MAX_SHARE_BYTES = ([\d_]+)L \* ([\d_]+)')),
      largestArchive,
    );
  });

  for (final path in [
    'ios/ShareExtension/ShareViewController.swift',
    'ios/Runner/ShareInbox.swift',
  ]) {
    test('iOS refuses shares above the largest archive ($path)', () {
      expect(
        capIn(path, RegExp(r'static let maxShareBytes = ([\d_]+) \* ([\d_]+)')),
        largestArchive,
      );
    });
  }
}
