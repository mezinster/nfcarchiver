import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Platform channel for NFC hardware capabilities Flutter cannot query itself.
const MethodChannel nfcCapabilitiesChannel =
    MethodChannel('com.nfcarchiver/nfc_capabilities');

/// Whether this device's NFC controller can talk to Mifare Classic cards.
///
/// Mifare Classic uses NXP's proprietary CRYPTO1 cipher rather than a standard
/// ISO 14443-4 protocol, so support lives in the controller chip: NXP
/// controllers have it, Broadcom and Samsung's S3FWRN5 generally do not, and
/// iOS never does. Any failure to answer is treated as "not supported" — the
/// feature is hidden rather than offered and then failing at tap.
Future<bool> hasMifareClassicSupport() async {
  try {
    final result =
        await nfcCapabilitiesChannel.invokeMethod<bool>('hasMifareClassic');
    return result ?? false;
  } on MissingPluginException {
    return false; // iOS, or an older build without the channel
  } on PlatformException {
    return false;
  }
}

/// Queried once and cached for the app's lifetime — hardware does not change.
final mifareSupportProvider =
    FutureProvider<bool>((ref) => hasMifareClassicSupport());
