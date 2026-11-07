import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
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
  test('Android 12+ asks for the two Android-12+ Bluetooth permissions', () {
    for (final sdk in [31, 34, 36]) {
      expect(
        bluetoothPermissionsFor(TargetPlatform.android, androidSdk: sdk),
        [Permission.bluetoothScan, Permission.bluetoothConnect],
        reason: 'API $sdk',
      );
    }
  });

  // Below Android 12 permission_handler reports bluetoothScan/Connect as
  // GRANTED without a dialog (they do not exist there), while the OS refuses
  // any BLE scan without location permission. Asking for them alone meant
  // the Chameleon could never be found on Android 7-11 (issue #104).
  test('Android 11 and older asks for location, which a BLE scan needs', () {
    for (final sdk in [24, 28, 29, 30]) {
      expect(
        bluetoothPermissionsFor(TargetPlatform.android, androidSdk: sdk),
        [Permission.locationWhenInUse],
        reason: 'API $sdk',
      );
    }
  });

  // Location is capped at maxSdkVersion 30 in the manifest; requesting it on
  // 12+ would come back denied and block the scan. Unknown means 12+.
  test('an unknown Android version keeps the Android 12+ behaviour', () {
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

  group('what a radio status means for the user', () {
    test('ready means nothing is in the way', () {
      expect(unavailableReasonFor(BleStatus.ready), isNull);
    });

    test('each blocking status names its own cause', () {
      expect(unavailableReasonFor(BleStatus.poweredOff),
          BleUnavailableReason.bluetoothOff);
      // Android 7-11 return no scan results while location services are
      // off, even with the permission granted. Saying "Bluetooth is off"
      // there sent users to a switch that was already on.
      expect(unavailableReasonFor(BleStatus.locationServicesDisabled),
          BleUnavailableReason.locationOff);
      expect(unavailableReasonFor(BleStatus.unauthorized),
          BleUnavailableReason.permissionDenied);
      expect(unavailableReasonFor(BleStatus.unsupported),
          BleUnavailableReason.unsupported);
    });

    test('a status not yet known is treated as off, as before', () {
      expect(unavailableReasonFor(BleStatus.unknown),
          BleUnavailableReason.bluetoothOff);
    });
  });

  // Seen on an Android 11 emulator: right after the location dialog is
  // accepted, the plugin's cached status still says `unauthorized` for a
  // moment, so the first Search after granting reported "permission required".
  group('settledStatus', () {
    test('ready is returned at once, without waiting', () async {
      // A grace of an hour would time the test out if it were waited on.
      expect(
        await settledStatus(BleStatus.ready, const Stream.empty(),
            grace: const Duration(hours: 1)),
        BleStatus.ready,
      );
    });

    test('a stale status gives way to ready when it arrives', () async {
      final updates = StreamController<BleStatus>();
      final result = settledStatus(BleStatus.unauthorized, updates.stream,
          grace: const Duration(seconds: 5));
      updates.add(BleStatus.ready);
      expect(await result, BleStatus.ready);
      await updates.close();
    });

    test('a status that stays blocked is reported after the grace period',
        () async {
      final updates = StreamController<BleStatus>();
      final result = settledStatus(BleStatus.poweredOff, updates.stream,
          grace: const Duration(milliseconds: 50));
      expect(await result, BleStatus.poweredOff);
      await updates.close();
    });

    test('the latest blocking status wins when ready never comes', () async {
      final updates = StreamController<BleStatus>();
      final result = settledStatus(BleStatus.unauthorized, updates.stream,
          grace: const Duration(milliseconds: 50));
      updates.add(BleStatus.locationServicesDisabled);
      expect(await result, BleStatus.locationServicesDisabled);
      await updates.close();
    });
  });
}
