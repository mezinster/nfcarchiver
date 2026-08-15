import 'package:flutter/foundation.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

/// Narrow NDEF access to a tag.
///
/// Exists for the same reason as [MifareBlockIO]: the platform NDEF classes
/// cannot be constructed in a test, so a codec that reaches for them directly is
/// only exercisable with a card in hand. Injecting the lookup instead lets the
/// codec's real logic run against a fake.
///
/// It is also the one place in `lib/` that names a platform NDEF class.
/// `nfc_manager` v4 dropped the platform-agnostic `Ndef` in favour of
/// [NdefAndroid] and [NdefIos], whose members diverge in both name and shape —
/// `maxSize` vs `capacity`, a bool `isWritable` vs an [NdefStatusIos] enum,
/// `getNdefMessage`/`writeNdefMessage` vs `readNdef`/`writeNdef`. Everything
/// above this file is spared that split.
abstract interface class NdefIO {
  /// Capacity of the NDEF *message* area, in bytes.
  int get maxSize;

  /// Whether the tag will accept a write.
  bool get isWritable;

  /// Read the stored NDEF message. A tag holding none reads as an empty
  /// message, never null — see [ndefMessageOrEmpty].
  Future<NdefMessage> read();

  /// Replace the stored NDEF message. Throws on failure.
  Future<void> write(NdefMessage message);
}

/// v3's `read()` returned a non-null message; v4 returns null when the tag holds
/// none. The app's existing meaning for a blank tag is "no chunk here", which
/// `NdefFormatter.ndefToChunk` already reports for a message with no records —
/// so null collapses to empty rather than propagating and crashing a null-check.
NdefMessage ndefMessageOrEmpty(NdefMessage? message) =>
    message ?? const NdefMessage(records: []);

/// iOS reports writability as a tri-state. Only [NdefStatusIos.readWrite]
/// accepts a write; treating `readOnly` or `notSupported` as writable would let
/// the codec attempt a write the tag then rejects.
bool isWritableIosStatus(NdefStatusIos status) =>
    status == NdefStatusIos.readWrite;

/// Android's NDEF technology.
class AndroidNdefIO implements NdefIO {
  AndroidNdefIO(this._ndef);
  final NdefAndroid _ndef;

  @override
  int get maxSize => _ndef.maxSize;

  @override
  bool get isWritable => _ndef.isWritable;

  @override
  Future<NdefMessage> read() async =>
      ndefMessageOrEmpty(await _ndef.getNdefMessage());

  @override
  Future<void> write(NdefMessage message) => _ndef.writeNdefMessage(message);
}

/// iOS's NDEF technology.
class IosNdefIO implements NdefIO {
  IosNdefIO(this._ndef);
  final NdefIos _ndef;

  @override
  int get maxSize => _ndef.capacity;

  @override
  bool get isWritable => isWritableIosStatus(_ndef.status);

  @override
  Future<NdefMessage> read() async =>
      ndefMessageOrEmpty(await _ndef.readNdef());

  @override
  Future<void> write(NdefMessage message) => _ndef.writeNdef(message);
}

/// Adapter used in production: null when the tag carries no NDEF technology.
///
/// Dispatches on the host platform rather than trying both, because
/// `NdefAndroid.from` and `NdefIos.from` each cast `tag.data` to their own
/// platform's payload type and would throw on the other's tag.
NdefIO? ndefIoFor(NfcTag tag) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      final ndef = NdefAndroid.from(tag);
      return ndef == null ? null : AndroidNdefIO(ndef);
    case TargetPlatform.iOS:
      final ndef = NdefIos.from(tag);
      return ndef == null ? null : IosNdefIO(ndef);
    default:
      return null;
  }
}
