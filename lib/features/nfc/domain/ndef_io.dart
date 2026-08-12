import 'package:nfc_manager/nfc_manager.dart';

/// Narrow NDEF access to a tag.
///
/// Exists for the same reason as [MifareBlockIO]: `nfc_manager`'s `Ndef` cannot
/// be constructed in a test, so a codec that calls `Ndef.from(tag)` directly is
/// only exercisable with a card in hand. Injecting the lookup instead lets the
/// codec's real logic run against a fake.
///
/// It also isolates the one place that names a platform NDEF class. `nfc_manager`
/// v4 replaces the platform-agnostic `Ndef` with separate `NdefAndroid` and
/// `NdefIos` types whose members differ (`maxSize` vs `capacity`, a bool
/// `isWritable` vs an `NdefStatusIos` enum), so that migration becomes a change
/// to the adapter below rather than to every call site.
abstract interface class NdefIO {
  /// Capacity of the NDEF *message* area, in bytes.
  int get maxSize;

  /// Whether the tag will accept a write.
  bool get isWritable;

  /// Read the stored NDEF message.
  Future<NdefMessage> read();

  /// Replace the stored NDEF message. Throws on failure.
  Future<void> write(NdefMessage message);
}

/// Real implementation over `nfc_manager`.
class NfcManagerNdefIO implements NdefIO {
  NfcManagerNdefIO(this._ndef);
  final Ndef _ndef;

  @override
  int get maxSize => _ndef.maxSize;

  @override
  bool get isWritable => _ndef.isWritable;

  @override
  Future<NdefMessage> read() => _ndef.read();

  @override
  Future<void> write(NdefMessage message) => _ndef.write(message);
}

/// Adapter used in production: null when the tag carries no NDEF technology.
NdefIO? ndefIoFor(NfcTag tag) {
  final ndef = Ndef.from(tag);
  return ndef == null ? null : NfcManagerNdefIO(ndef);
}
