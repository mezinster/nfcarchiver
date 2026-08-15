import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import 'ndef_formatter.dart';
import 'ndef_io.dart';
import 'tag_codec.dart';

/// NDEF-backed tags: NTAG213/215/216 and Mifare Ultralight.
class NdefTagCodec implements TagCodec {
  NdefTagCodec(this._ioFor, [NdefFormatter? formatter])
      : _formatter = formatter ?? NdefFormatter.instance;

  /// Injected so the codec is testable without a card — see [NdefIO].
  final NdefIO? Function(NfcTag tag) _ioFor;
  final NdefFormatter _formatter;

  @override
  String get name => 'NDEF';

  @override
  bool supports(NfcTag tag) => _ioFor(tag) != null;

  @override
  Future<int> capacityBytes(NfcTag tag) async {
    final ndef = _ioFor(tag)!;
    // ndef.maxSize is the NDEF *message* capacity. Subtract the record overhead
    // and the terminator byte to get the chunk bytes that actually fit.
    //
    // Unused in the live write path: the NDEF size check there compares
    // `requiredNdefSize(chunk)` against `ndef.maxSize` directly (see
    // nfc_repository.dart). This method reduces to `ndef.maxSize - 40`,
    // which is 1-4 bytes stricter than that live comparison, so wiring it in
    // would reject some chunks the app accepts today. Anyone unifying the
    // two must first prove the NDEF accept/reject decision is unchanged for
    // every chunk size.
    return NfcTagType.maxPayloadForCapacity(ndef.maxSize) +
        NfarHeaderSize.total;
  }

  @override
  Future<Chunk?> readChunk(NfcTag tag) async {
    final ndef = _ioFor(tag)!;
    return _formatter.ndefToChunk(await ndef.read());
  }

  @override
  Future<void> writeChunk(NfcTag tag, Chunk chunk) async {
    final ndef = _ioFor(tag)!;
    if (!ndef.isWritable) {
      throw StateError('Tag is not writable');
    }
    await ndef.write(_formatter.chunkToNdef(chunk));
  }
}
