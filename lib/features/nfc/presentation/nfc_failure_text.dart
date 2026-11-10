import '../../../l10n/app_localizations.dart';
import '../domain/nfc_failure.dart';

/// The user's words for [f]. Never includes exception text: that lives only in
/// the diagnostics log.
String nfcFailureText(NfcFailure f, AppLocalizations l10n) {
  switch (f.kind) {
    case NfcFailureKind.noArchiveData:
      return l10n.nfcNoArchiveData;
    case NfcFailureKind.readFailed:
    case NfcFailureKind.detectionFailed:
      return l10n.nfcReadFailed;
    case NfcFailureKind.writeFailed:
      return l10n.nfcWriteFailed;
    case NfcFailureKind.tagNotWritable:
      return l10n.nfcTagNotWritable;
    case NfcFailureKind.notNdefFormatted:
      return l10n.nfcNotNdefFormatted;
    case NfcFailureKind.mifareUnsupported:
      return l10n.nfcMifareUnsupported;
    case NfcFailureKind.foreignCard:
      return l10n.nfcForeignCard;
    case NfcFailureKind.nfcUnavailable:
      return l10n.nfcUnavailable;
    case NfcFailureKind.unknown:
      return l10n.somethingWentWrong;
  }
}

/// Whether [f] is an expected outcome rather than a fault — a tag with no
/// archive data on it is a normal thing to tap during a restore.
bool isNeutral(NfcFailure f) => f.kind == NfcFailureKind.noArchiveData;
