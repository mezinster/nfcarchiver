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

/// Finds Chameleons advertising the Nordic UART service.
///
/// Thin by design: everything it wraps needs a radio, so keeping it small keeps
/// the untestable surface small.
class BleScanner {
  BleScanner({FlutterReactiveBle? ble}) : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  /// Ask for the runtime permissions Android 12+ requires.
  ///
  /// BLUETOOTH_SCAN is declared with `neverForLocation`, so no location
  /// permission is requested and the app never looks like it is tracking
  /// anyone — which also keeps F-Droid's anti-feature checks satisfied.
  Future<void> ensurePermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
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
