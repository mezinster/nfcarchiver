/// Why an NFC read or write did not produce a result.
///
/// Typed rather than a string so the screens can say it in the user's
/// language — and so no exception text, PlatformException message or native
/// stack can travel to the UI. The exception behind a failure goes to the
/// diagnostics log at the throw site; the failure itself carries none of it.
enum NfcFailureKind {
  /// The tag was read fine but holds no NFAR chunk (blank or foreign content).
  noArchiveData,

  /// I/O or platform failure while reading.
  readFailed,

  /// I/O or platform failure while writing.
  writeFailed,

  /// The tag is read-only.
  tagNotWritable,

  /// No NFC-A technology: nothing an NDEF message can be written to.
  notNdefFormatted,

  /// NDEF detection did not finish during discovery — usually a retry fixes it.
  detectionFailed,

  /// A Mifare Classic card on a phone whose controller cannot do CRYPTO1.
  mifareUnsupported,

  /// A Mifare Classic card keyed with keys the app does not have.
  foreignCard,

  /// The reader's NFC is off or absent.
  nfcUnavailable,

  /// Anything else; the log has the detail.
  unknown,
}

class NfcFailure {
  const NfcFailure(this.kind);

  final NfcFailureKind kind;

  @override
  bool operator ==(Object other) => other is NfcFailure && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'NfcFailure(${kind.name})';
}
