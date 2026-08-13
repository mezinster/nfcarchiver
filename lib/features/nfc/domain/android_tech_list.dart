/// Reading Android's tag technology list.
///
/// Android reports a tapped tag's technologies as fully-qualified Java class
/// names — `android.nfc.tech.NfcA`, `android.nfc.tech.MifareUltralight`, and so
/// on. `nfc_manager` v3 flattened that into an untyped map the app probed by
/// key (`tag.data['nfca']`); v4 exposes `NfcTagAndroid.techList` as a typed
/// `List<String>`, so the lookup lives here instead of being spread through the
/// repository as map indexing.
library;

const String _androidTechPrefix = 'android.nfc.tech.';

/// Whether the tag exposed [simpleName], e.g. `'NfcA'`.
///
/// Matches the whole class name rather than a substring: `'NfcA'` occurs inside
/// `'android.nfc.tech.NfcAFoo'`, and a `contains` check would claim a
/// technology the tag does not have.
bool androidHasTech(List<String> techList, String simpleName) =>
    techList.contains('$_androidTechPrefix$simpleName');

/// The short technology names the app displays, in the order the platform
/// reported them. A name without the usual package prefix passes through
/// unchanged rather than being dropped.
List<String> androidTechLabels(List<String> techList) => techList
    .map((t) => t.startsWith(_androidTechPrefix)
        ? t.substring(_androidTechPrefix.length)
        : t)
    .toList();
