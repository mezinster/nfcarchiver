import 'card_layout.dart';

/// What a tapped tag's SAK byte says it is, as far as this app cares.
enum TagKind { classic1k, classic4k, ntag, unsupported }

/// Classify a SAK. Anything unrecognised (Mifare Mini 0x09, Classic 2K 0x19,
/// ...) is [TagKind.unsupported]: the layout only knows 1K and 4K geometry.
TagKind classifySak(int sak) {
  switch (sak) {
    case 0x08:
      return TagKind.classic1k;
    case 0x18:
    case 0x38:
    case 0x98:
      return TagKind.classic4k;
    case 0x00:
      return TagKind.ntag;
    default:
      return TagKind.unsupported;
  }
}

/// Card geometry for a Classic [kind]; null for non-Classic kinds.
MifareCardSize? cardSizeFor(TagKind kind) {
  switch (kind) {
    case TagKind.classic1k:
      return MifareCardSize.k1;
    case TagKind.classic4k:
      return MifareCardSize.k4;
    case TagKind.ntag:
    case TagKind.unsupported:
      return null;
  }
}
