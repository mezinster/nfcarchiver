/// Explains why a discovered tag exposed no NDEF technology.
///
/// On Android the `Ndef` tech is attached to a tag only if the platform's NFC
/// service completed NDEF detection during discovery: read the capability
/// container, walk the TLVs, and parse the `NdefMessage`. Detecting a full
/// NTAG215 takes ~31 READ commands, so a brief or badly-coupled tap aborts the
/// walk on a perfectly good tag. The tag then surfaces with only `NfcA` /
/// `MifareUltralight`, `Ndef.from(tag)` returns null, and the two conditions
/// are indistinguishable at that call site — which is why both used to be
/// reported as "use a pre-formatted NDEF tag", a permanent-sounding message for
/// what is usually a retry.
library;

import 'nfc_failure.dart';

enum NdefUnavailableReason {
  /// The tag exposes NFC-A technology, so it is a real tag the reader talked
  /// to — NDEF detection simply did not finish. Retrying the tap usually works.
  detectionFailed,

  /// No NFC-A technology at all: nothing we can write an NDEF message to.
  notNdefFormatted,

  /// The tag exposes NFC-A but neither Ndef nor MifareClassic, on a phone whose
  /// controller cannot do CRYPTO1 — the signature of a Mifare Classic card on
  /// hardware that will never read it. Retrying cannot help.
  mifareUnsupported,
}

/// Classify a tag that came back without the `Ndef` technology.
NdefUnavailableReason classifyNdefUnavailable({
  required bool hasNfcA,
  required bool hasMifareUltralight,
  required bool deviceSupportsMifare,
}) {
  if (hasMifareUltralight) return NdefUnavailableReason.detectionFailed;
  if (hasNfcA) {
    return deviceSupportsMifare
        ? NdefUnavailableReason.detectionFailed
        : NdefUnavailableReason.mifareUnsupported;
  }
  return NdefUnavailableReason.notNdefFormatted;
}

/// The typed failure for [reason]; the screen turns it into localized text.
NfcFailure failureFor(NdefUnavailableReason reason) {
  switch (reason) {
    case NdefUnavailableReason.detectionFailed:
      return const NfcFailure(NfcFailureKind.detectionFailed);
    case NdefUnavailableReason.notNdefFormatted:
      return const NfcFailure(NfcFailureKind.notNdefFormatted);
    case NdefUnavailableReason.mifareUnsupported:
      return const NfcFailure(NfcFailureKind.mifareUnsupported);
  }
}
