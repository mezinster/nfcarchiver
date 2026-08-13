import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/chameleon/ble_chameleon_device.dart';
import '../../../core/log/logger.dart';

/// A Chameleon seen while scanning.
class DiscoveredReader {
  const DiscoveredReader({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;
}

/// Why a scan could not start. Distinguished so the UI can say something
/// actionable instead of showing an empty list and letting the user conclude
/// their reader is broken.
enum BleUnavailableReason { permissionDenied, bluetoothOff, unsupported }

class BleUnavailableException implements Exception {
  const BleUnavailableException(this.reason);
  final BleUnavailableReason reason;
  @override
  String toString() => 'BleUnavailableException: $reason';
}

/// The runtime permissions a BLE scan needs on [platform].
///
/// `bluetoothScan`/`bluetoothConnect` are Android-12+ runtime permissions. iOS
/// has no equivalent: Core Bluetooth is gated by the
/// `NSBluetoothAlwaysUsageDescription` string in `ios/Runner/Info.plist`, and
/// the system shows its own prompt on first use.
///
/// Asking anyway on iOS is not harmless. permission_handler has no iOS
/// implementation for them, so they come back denied and [BleScanner
/// .ensurePermissions] would reject the scan before it starts — locking the
/// Chameleon out of the platform that needs it most, since Core NFC cannot read
/// Mifare Classic at all and the reader is iOS's only route to those cards.
List<Permission> bluetoothPermissionsFor(TargetPlatform platform) =>
    platform == TargetPlatform.android
        ? const [Permission.bluetoothScan, Permission.bluetoothConnect]
        : const [];

/// Finds Chameleons advertising the Nordic UART service.
///
/// Thin by design: everything it wraps needs a radio, so keeping it small keeps
/// the untestable surface small.
class BleScanner {
  BleScanner({FlutterReactiveBle? ble}) : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  /// Ask for whatever runtime permissions this platform requires.
  ///
  /// BLUETOOTH_SCAN is declared with `neverForLocation`, so no location
  /// permission is requested and the app never looks like it is tracking
  /// anyone — which also keeps F-Droid's anti-feature checks satisfied.
  Future<void> ensurePermissions() async {
    final wanted = bluetoothPermissionsFor(defaultTargetPlatform);
    if (wanted.isEmpty) {
      log.debug('scan', 'No runtime Bluetooth permissions on this platform');
      return;
    }
    final results = await wanted.request();
    log.info('scan', 'Permission results', {
      for (final e in results.entries) e.key.toString(): e.value.toString(),
    });
    final denied = results.values.any((s) => !s.isGranted);
    if (denied) {
      throw const BleUnavailableException(BleUnavailableReason.permissionDenied);
    }
  }

  /// Devices advertising the Chameleon's service, newest RSSI first.
  ///
  /// Filtered by service UUID rather than by name: a renamed Chameleon is
  /// still a Chameleon, and name matching would quietly hide it.
  Stream<DiscoveredReader> scan() => _ble
          .scanForDevices(withServices: [BleChameleonDevice.serviceUuid])
          .map((d) {
            log.debug('scan', 'Advertisement', {
              'id': d.id,
              'name': d.name,
              'rssi': d.rssi,
            });
            return DiscoveredReader(
                id: d.id,
                name: d.name.isEmpty ? 'Chameleon' : d.name,
                rssi: d.rssi,
            );
          });

  /// Whether the radio is on and usable right now.
  Future<bool> isBluetoothReady() async =>
      _ble.status == BleStatus.ready;
}
