import '../../../core/constants/nfar_format.dart';

/// The tag types a user may choose from, given what the active reader can do.
///
/// Pure so the rule can be tested without a widget: which media are on offer
/// is a capability decision, and burying it in a `build` method is how it came
/// to ask the wrong question in the first place — the phone's controller
/// instead of the reader's.
///
/// [NfcTagType.custom] is never offered: it carries no capacity of its own and
/// exists for the rechunk path, not for selection.
///
/// A type whose [NfcTagType.maxPayloadSize] is not positive is never offered
/// either: plain MIFARE Ultralight (48 B) is smaller than the NDEF wrapper plus
/// the NFAR header and CRC. It stays in the enum so a tapped one is still
/// recognised.
///
/// [NfcTagType.mifareClassic4k] additionally needs [mifare4kEnabled], the
/// developer switch: writing 4K is experimental until verified on a real card.
List<NfcTagType> selectableTagTypes({
  required bool mifareAvailable,
  required bool mifare4kEnabled,
}) =>
    NfcTagType.values
        .where((t) => t != NfcTagType.custom)
        .where((t) => t.maxPayloadSize > 0)
        .where((t) => t.medium != TagMedium.mifareClassic || mifareAvailable)
        .where((t) => t != NfcTagType.mifareClassic4k || mifare4kEnabled)
        .toList(growable: false);
