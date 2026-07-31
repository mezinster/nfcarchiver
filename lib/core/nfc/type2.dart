import 'dart:typed_data';

import 'ndef_bytes.dart';

/// NFC-Forum Type-2 tag helpers: NDEF-message TLV framing (written from page
/// 4), NTAG type detection, and per-type geometry.
///
/// Port of `webapp/src/nfc/type2.ts`.

/// The page an NDEF TLV starts at on every NTAG. Pages 0–3 are UID, lock bytes
/// and the capability container.
const int ndefStartPage = 4;

/// The NTAG chips this app reads and writes.
enum NtagType { ntag213, ntag215, ntag216 }

/// Frame an NDEF message as a Type-2 NDEF TLV, terminator included.
///
/// The length field has two forms and the boundary is easy to get wrong: one
/// byte below 255, otherwise `0xFF` followed by a 16-bit length. Choosing the
/// short form at 255 would corrupt every card larger than an NTAG213, and it
/// is invisible on small test payloads.
Uint8List wrapType2Tlv(Uint8List ndef) {
  if (ndef.length < 0xff) {
    final out = Uint8List(2 + ndef.length + 1);
    out[0] = 0x03;
    out[1] = ndef.length;
    out.setRange(2, 2 + ndef.length, ndef);
    out[out.length - 1] = 0xfe;
    return out;
  }
  final out = Uint8List(4 + ndef.length + 1);
  out[0] = 0x03;
  out[1] = 0xff;
  out[2] = (ndef.length >> 8) & 0xff;
  out[3] = ndef.length & 0xff;
  out.setRange(4, 4 + ndef.length, ndef);
  out[out.length - 1] = 0xfe;
  return out;
}

/// Find and return the NDEF message inside Type-2 tag memory.
///
/// Walks the TLV chain, skipping NULL (0x00), lock-control (0x01) and
/// memory-control (0x02) entries, and stops at the terminator (0xFE).
///
/// Throws [NdefFormatException] while the TLV is still incomplete — which is
/// exactly what the inspector needs mid-dump: "no complete NDEF TLV yet" is a
/// different fact from "this tag holds no NFAR chunk".
Uint8List readType2Ndef(Uint8List memory) {
  var i = 0;
  while (i < memory.length) {
    final tag = memory[i];
    if (tag == 0x00) {
      i += 1;
      continue;
    }
    if (tag == 0xfe) break;
    if (i + 1 >= memory.length) break;

    var len = memory[i + 1];
    var valueStart = i + 2;
    if (len == 0xff) {
      if (i + 3 >= memory.length) break;
      len = (memory[i + 2] << 8) | memory[i + 3];
      valueStart = i + 4;
    }

    if (tag == 0x03) {
      if (valueStart + len > memory.length) {
        throw const NdefFormatException(
          'NDEF TLV runs past end of tag memory',
        );
      }
      return Uint8List.sublistView(memory, valueStart, valueStart + len);
    }
    i = valueStart + len;
  }
  throw const NdefFormatException('No NDEF TLV found in tag memory');
}

/// Bytes of *user* memory — the NDEF data area only.
const Map<NtagType, int> _userBytes = {
  NtagType.ntag213: 144,
  NtagType.ntag215: 504,
  NtagType.ntag216: 888,
};

/// Total pages per type **including** the config and lock pages, not just user
/// memory. A raw dump needs all of them; [ntagUserBytes] covers only the NDEF
/// area, and using it here would silently truncate every dump.
const Map<NtagType, int> _totalPages = {
  NtagType.ntag213: 45,
  NtagType.ntag215: 135,
  NtagType.ntag216: 231,
};

int ntagUserBytes(NtagType t) => _userBytes[t]!;

int ntagTotalPages(NtagType t) => _totalPages[t]!;

/// Identify the chip from an NTAG `GET_VERSION` (0x60) response.
///
/// Byte 6 is the storage-size code. Returns null for anything unrecognised —
/// callers turn that into an "unsupported tag" message that names the byte,
/// because for the card inspector that value is the finding.
NtagType? detectNtagType(Uint8List getVersion) {
  if (getVersion.length < 7) return null;
  switch (getVersion[6]) {
    case 0x0f:
      return NtagType.ntag213;
    case 0x11:
      return NtagType.ntag215;
    case 0x13:
      return NtagType.ntag216;
    default:
      return null;
  }
}

/// Human label for a chip, used in inspector output.
String ntagLabel(NtagType t) => switch (t) {
      NtagType.ntag213 => 'NTAG213',
      NtagType.ntag215 => 'NTAG215',
      NtagType.ntag216 => 'NTAG216',
    };
