import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import 'ndef_formatter.dart';
import 'tag_codec.dart';

/// NDEF-backed tags: NTAG213/215/216 and Mifare Ultralight.
class NdefTagCodec implements TagCodec {
  NdefTagCodec([NdefFormatter? formatter])
      : _formatter = formatter ?? NdefFormatter.instance;

  final NdefFormatter _formatter;

  @override
  String get name => 'NDEF';

  @override
  bool supports(NfcTag tag) => Ndef.from(tag) != null;

  @override
  Future<int> capacityBytes(NfcTag tag) async {
    final ndef = Ndef.from(tag)!;
    // ndef.maxSize is the NDEF *message* capacity. Subtract the record overhead
    // and the terminator byte to get the chunk bytes that actually fit.
    return NfcTagType.maxPayloadForCapacity(ndef.maxSize) +
        NfarHeaderSize.total;
  }

  @override
  Future<Chunk?> readChunk(NfcTag tag) async {
    final ndef = Ndef.from(tag)!;
    return _formatter.ndefToChunk(await ndef.read());
  }

  @override
  Future<void> writeChunk(NfcTag tag, Chunk chunk) async {
    final ndef = Ndef.from(tag)!;
    if (!ndef.isWritable) {
      throw StateError('Tag is not writable');
    }
    await ndef.write(_formatter.chunkToNdef(chunk));
  }
}
