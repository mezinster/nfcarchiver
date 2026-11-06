import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// The technologies every NFC session polls for.
///
/// nfc_manager v4 requires the set explicitly; v3 defaulted to all of them.
/// Never narrow it below ISO 14443 (NTAG, Mifare Classic) and ISO 15693, or
/// tags silently stop being discovered.
///
/// iOS leaves out ISO 18092 (FeliCa). Core NFC only lets a session poll it when
/// Info.plist lists FeliCa system codes in
/// `com.apple.developer.nfc.readersession.felica.systemcodes`; ours lists none,
/// so asking for it got the session invalidated with "Missing required
/// entitlement" on the first tap. The app has no FeliCa medium, so nothing is
/// lost. Android keeps everything — it is validated on hardware that way.
Set<NfcPollingOption> sessionPollingOptions() {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return {NfcPollingOption.iso14443, NfcPollingOption.iso15693};
  }
  return NfcPollingOption.values.toSet();
}
