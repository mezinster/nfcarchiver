import 'dart:convert';
import 'dart:typed_data';

/// Byte-level NDEF record codec for one NFAR chunk.
///
/// **Why this exists alongside `NdefFormatter`.** That class works on
/// `nfc_manager`'s `NdefMessage`/`NdefRecord` objects, which the phone's NFC
/// stack hands over already parsed. A Chameleon provides no such thing — it
/// returns raw pages — so reading or writing NTAG over BLE needs the record
/// built and parsed from bytes. The two are complementary, not duplicates.
///
/// Produces a single NDEF MIME record (TNF=media) byte-identical to what
/// Android's `NdefRecord.createMime` emits, so a tag written over a Chameleon
/// stays readable by the phone path and by any NFC phone.
///
/// Port of `webapp/src/nfc/ndef.ts`.

const String ndefMimeType = 'application/vnd.nfcarchiver.chunk';
final Uint8List _mimeBytes = Uint8List.fromList(utf8.encode(ndefMimeType));

class NdefFormatException implements Exception {
  const NdefFormatException(this.message);
  final String message;
  @override
  String toString() => 'NdefFormatException: $message';
}

/// Wrap [payload] in a single NDEF MIME record.
Uint8List encodeNdefMime(Uint8List payload) {
  final short = payload.length < 256;
  // MB | ME | TNF(media) | SR when the payload fits one length byte.
  final flags = 0x80 | 0x40 | 0x02 | (short ? 0x10 : 0);
  final lenBytes = short ? 1 : 4;
  final out = Uint8List(2 + lenBytes + _mimeBytes.length + payload.length);

  var i = 0;
  out[i++] = flags;
  out[i++] = _mimeBytes.length;
  if (short) {
    out[i++] = payload.length;
  } else {
    out[i++] = (payload.length >> 24) & 0xff;
    out[i++] = (payload.length >> 16) & 0xff;
    out[i++] = (payload.length >> 8) & 0xff;
    out[i++] = payload.length & 0xff;
  }
  out.setRange(i, i + _mimeBytes.length, _mimeBytes);
  i += _mimeBytes.length;
  out.setRange(i, i + payload.length, payload);
  return out;
}

bool _mimeEquals(Uint8List bytes, int start) {
  if (start + _mimeBytes.length > bytes.length) return false;
  for (var k = 0; k < _mimeBytes.length; k++) {
    if (bytes[start + k] != _mimeBytes[k]) return false;
  }
  return true;
}

/// Extract the chunk from an NDEF MIME record.
///
/// Throws [NdefFormatException] when the record is not ours — which the card
/// inspector reports as a distinct, permanent fact ("valid NDEF, different MIME
/// type") rather than collapsing it into "no chunk found".
Uint8List decodeNdefMime(Uint8List ndef) {
  if (ndef.length < 3) {
    throw const NdefFormatException('NDEF record too short');
  }
  final flags = ndef[0];
  final tnf = flags & 0x07;
  if (tnf != 0x02) {
    throw NdefFormatException('Unexpected TNF $tnf (want media)');
  }
  final short = (flags & 0x10) != 0;
  final typeLen = ndef[1];

  var i = 2;
  int payloadLen;
  if (short) {
    payloadLen = ndef[i];
    i += 1;
  } else {
    if (ndef.length < 6) {
      throw const NdefFormatException('NDEF record too short for a long length');
    }
    payloadLen =
        (ndef[i] << 24) | (ndef[i + 1] << 16) | (ndef[i + 2] << 8) | ndef[i + 3];
    i += 4;
  }

  if (typeLen != _mimeBytes.length || !_mimeEquals(ndef, i)) {
    throw const NdefFormatException(
      'Not an NFAR NDEF record (MIME type mismatch)',
    );
  }
  i += typeLen;
  if (i + payloadLen > ndef.length) {
    throw const NdefFormatException('NDEF payload runs past end of record');
  }
  return Uint8List.sublistView(ndef, i, i + payloadLen);
}
