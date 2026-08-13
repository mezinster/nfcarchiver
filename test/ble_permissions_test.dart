import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/ble_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

/// Which runtime permissions the BLE scan needs, per platform.
///
/// `Permission.bluetoothScan` and `Permission.bluetoothConnect` are Android-12+
/// concepts. iOS has no runtime Bluetooth permission at all — Core Bluetooth is
/// gated by the `NSBluetoothAlwaysUsageDescription` string in Info.plist, and
/// the system shows its own prompt on first use.
///
/// Requesting them anyway on iOS is not harmless: permission_handler reports
/// them as denied because no iOS implementation exists, and the scan then
/// refuses to start with BleUnavailableReason.permissionDenied — blocking the
/// Chameleon on the one platform where it matters most, since Core NFC cannot
/// read Mifare Classic at all.
void main() {
  test('Android asks for the two Android-12+ Bluetooth permissions', () {
    expect(
      bluetoothPermissionsFor(TargetPlatform.android),
      [Permission.bluetoothScan, Permission.bluetoothConnect],
    );
  });

  test('iOS asks for nothing — Core Bluetooth has no runtime permission', () {
    expect(bluetoothPermissionsFor(TargetPlatform.iOS), isEmpty);
  });

  test('other platforms ask for nothing', () {
    for (final p in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      expect(bluetoothPermissionsFor(p), isEmpty, reason: '$p');
    }
  });
}
