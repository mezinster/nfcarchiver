import 'dart:typed_data';

/// The NTAG chips this app reads and writes.
///
/// Port of the geometry half of `webapp/src/nfc/type2.ts`. The Type-2 TLV /
/// NDEF envelope helpers live alongside these once the raw codec lands.
enum NtagType { ntag213, ntag215, ntag216 }

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
