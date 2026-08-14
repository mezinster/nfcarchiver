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
List<NfcTagType> selectableTagTypes({required bool mifareAvailable}) =>
    NfcTagType.values
        .where((t) => t != NfcTagType.custom)
        .where((t) => t.medium != TagMedium.mifareClassic || mifareAvailable)
        .toList(growable: false);
