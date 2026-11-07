import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/chameleon/ble_chameleon_device.dart';
import '../../../core/log/logger.dart';
import 'nfc_capabilities.dart';

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
enum BleUnavailableReason {
  permissionDenied,

  /// Android 11 and older: location permission refused. The OS allows no BLE
  /// scan without it, so the message must explain why a Bluetooth feature asks.
  locationPermissionDenied,
  bluetoothOff,

  /// Android 11 and older: location services switched off. Scans then return
  /// nothing even with the permission granted.
  locationOff,
  unsupported,
}

class BleUnavailableException implements Exception {
  const BleUnavailableException(this.reason);
  final BleUnavailableReason reason;
  @override
  String toString() => 'BleUnavailableException: $reason';
}

/// The runtime permissions a BLE scan needs on [platform].
///
/// Android 12+ (API 31+): `bluetoothScan`/`bluetoothConnect`. BLUETOOTH_SCAN is
/// declared `neverForLocation`, so no location permission is involved.
///
/// Android 11 and older: `locationWhenInUse`. The OS refuses any BLE scan
/// without location permission, and permission_handler reports
/// `bluetoothScan`/`bluetoothConnect` as granted there without a dialog (they
/// do not exist before API 31), so asking only for those never asked for what
/// the scan needs — the Chameleon could not be found on Android 7–11 (issue
/// #104). The manifest caps location at maxSdkVersion 30, so it must never be
/// requested on 12+: it would come back denied and block the scan. An unknown
/// [androidSdk] therefore means 12+.
///
/// iOS has no equivalent: Core Bluetooth is gated by the
/// `NSBluetoothAlwaysUsageDescription` string in `ios/Runner/Info.plist`, and
/// the system shows its own prompt on first use.
///
/// Asking anyway on iOS is not harmless. permission_handler has no iOS
/// implementation for them, so they come back denied and [BleScanner
/// .ensurePermissions] would reject the scan before it starts — locking the
/// Chameleon out of the platform that needs it most, since Core NFC cannot read
/// Mifare Classic at all and the reader is iOS's only route to those cards.
List<Permission> bluetoothPermissionsFor(
  TargetPlatform platform, {
  int? androidSdk,
}) {
  if (platform != TargetPlatform.android) return const [];
  if (androidSdk != null && androidSdk <= 30) {
    return const [Permission.locationWhenInUse];
  }
  return const [Permission.bluetoothScan, Permission.bluetoothConnect];
}

/// What [status] means for someone trying to scan, or null if nothing blocks.
///
/// `unknown` (the radio has not reported yet) keeps its old meaning of "off".
BleUnavailableReason? unavailableReasonFor(BleStatus status) =>
    switch (status) {
      BleStatus.ready => null,
      BleStatus.locationServicesDisabled => BleUnavailableReason.locationOff,
      BleStatus.unauthorized => BleUnavailableReason.permissionDenied,
      BleStatus.unsupported => BleUnavailableReason.unsupported,
      BleStatus.poweredOff ||
      BleStatus.unknown =>
        BleUnavailableReason.bluetoothOff,
    };

/// [current], or — if it is not `ready` — whatever [updates] says within
/// [grace]: `ready` as soon as it arrives, otherwise the latest status seen.
///
/// The plugin's cached status lags behind a permission grant: on an Android 11
/// emulator it still read `unauthorized` right after the location dialog was
/// accepted, so the first Search after granting reported "permission required"
/// and only a second tap worked.
Future<BleStatus> settledStatus(
  BleStatus current,
  Stream<BleStatus> updates, {
  Duration grace = const Duration(seconds: 3),
}) async {
  if (current == BleStatus.ready) return current;
  var latest = current;
  final done = Completer<BleStatus>();
  final sub = updates.listen((s) {
    latest = s;
    if (s == BleStatus.ready && !done.isCompleted) done.complete(s);
  });
  final timer = Timer(grace, () {
    if (!done.isCompleted) done.complete(latest);
  });
  try {
    return await done.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// Finds Chameleons advertising the Nordic UART service.
///
/// Thin by design: everything it wraps needs a radio, so keeping it small keeps
/// the untestable surface small.
class BleScanner {
  BleScanner({FlutterReactiveBle? ble, Future<int?> Function()? androidSdk})
      : _ble = ble ?? FlutterReactiveBle(),
        _androidSdk = androidSdk ?? androidSdkInt;

  final FlutterReactiveBle _ble;
  final Future<int?> Function() _androidSdk;

  /// Ask for whatever runtime permissions this platform requires.
  ///
  /// See [bluetoothPermissionsFor]: Bluetooth permissions on Android 12+,
  /// location on Android 11 and older, nothing on iOS.
  Future<void> ensurePermissions() async {
    final platform = defaultTargetPlatform;
    final sdk = platform == TargetPlatform.android ? await _androidSdk() : null;
    final wanted = bluetoothPermissionsFor(platform, androidSdk: sdk);
    if (wanted.isEmpty) {
      log.debug('scan', 'No runtime Bluetooth permissions on this platform');
      return;
    }
    final results = await wanted.request();
    log.info('scan', 'Permission results', {
      'sdk': sdk,
      for (final e in results.entries) e.key.toString(): e.value.toString(),
    });
    final denied = results.values.any((s) => !s.isGranted);
    if (denied) {
      throw BleUnavailableException(
        wanted.contains(Permission.locationWhenInUse)
            ? BleUnavailableReason.locationPermissionDenied
            : BleUnavailableReason.permissionDenied,
      );
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

  /// What stops a scan right now, or null if the radio is usable.
  Future<BleUnavailableReason?> unavailableReason() async {
    final cached = _ble.status;
    final status = await settledStatus(cached, _ble.statusStream);
    log.debug('scan', 'Radio status', {
      'cached': cached.toString(),
      'status': status.toString(),
    });
    return unavailableReasonFor(status);
  }
}
