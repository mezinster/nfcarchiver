# Mifare Classic 1K support in the Flutter app

**Date:** 2026-07-31
**Scope:** The Flutter app only. Adds Mifare Classic 1K read and write on Android
phones whose NFC controller supports it, using the same raw-block NFAR layout the
web app already writes. No change to the NFAR format, the web app, or the
on-tag bytes.

## Problem

The web app writes Mifare Classic 1K cards as raw NFAR blocks — the chunk laid
across the 47 usable blocks, block 0 and every sector trailer skipped
(`webapp/src/mifare/card-layout.ts`). There is no NDEF framing, because Mifare
Classic is not an NDEF medium in this design.

The Flutter app is NDEF-only. Both its read and write paths call `Ndef.from(tag)`
and give up when it returns null (`nfc_repository.dart:80`, `:139`). For a
webapp-written Mifare card that is exactly what happens.

**So the phone can neither read nor write any Mifare archive the web app
produced.** Those cards are invisible to it. That quietly splits a user's card
collection into two incompatible families: NTAG cards both apps can handle, and
Mifare cards only the Chameleon can. Closing this is worth more than the
convenience of one more tag type.

The capability exists and is already a dependency: `nfc_manager` 3.5.0 ships a
`MifareClassic` platform tag exposing `authenticateSectorWithKeyA`, `readBlock`
and `writeBlock` — a near-exact match for the web app's `ChameleonDevice` seam.

## Constraint that shapes everything

Mifare Classic uses NXP's proprietary CRYPTO1 cipher rather than a standard
ISO 14443-4 protocol, so support lives in the phone's NFC controller. Devices
with NXP controllers have it; Broadcom and Samsung's own S3FWRN5 generally do
not. **iOS never will** — Core NFC has no CRYPTO1 support at all, so this is an
Android-only feature permanently.

CRYPTO1 is also cryptographically broken and NXP has deprecated Classic. That is
acceptable for an archival hobby format, but it means we are building on a
declining base and should not invest beyond what interop requires.

## Decisions (confirmed with user)

1. **Read and write**, not read-only. Being able to read cards you cannot write
   is a strange place to stop.
2. **Hide the option on unsupported devices**, and explain on tap. No dead UI on
   hardware that will never support it; restore, which has no picker, gets a
   specific message instead.
3. **Explicit medium selection.** "Mifare Classic 1K" joins the tag-type picker;
   a mismatched tap produces a clear error. No cross-medium re-chunking.
4. **A `TagCodec` strategy seam**, mirroring the web app's `Transport`, rather
   than branching inside `NfcRepository`.
5. **Factory keys only** (`FF FF FF FF FF FF`, key A) — supporting custom keys
   would break the interop this feature exists to create.
6. **Sector trailers are never written.** Cards stay factory-keyed and
   re-writable, matching `USABLE_BLOCK_INDEXES` in the web app.

## Architecture

### Capability detection

Flutter cannot reach `PackageManager`, so this needs the one piece of native code
in the feature: a platform channel `com.nfcarchiver/nfc_capabilities` with a
single method `hasMifareClassic`, implemented in `MainActivity.kt` as
`packageManager.hasSystemFeature("com.nxp.mifare")`. iOS returns `false`
unconditionally.

Detection happens at two levels, because the feature flag and the runtime truth
can disagree:

- the **flag** gates the UI — whether "Mifare Classic 1K" appears in the picker
- **`MifareClassic.from(tag) != null`** gates the operation — whether this
  particular tap can proceed

The flag is queried once at startup and exposed as a Riverpod provider.

### The `TagCodec` seam

```dart
abstract interface class TagCodec {
  String get name;
  bool supports(NfcTag tag);
  Future<int> capacityBytes(NfcTag tag);
  Future<Chunk?> readChunk(NfcTag tag);
  Future<void> writeChunk(NfcTag tag, Chunk chunk);
}
```

`NdefTagCodec` wraps today's logic and `NdefFormatter` without behaviour change.
`MifareClassicTagCodec` authenticates each sector with factory key A and then
reads or writes the usable blocks. `NfcRepository` holds an ordered list of
codecs, selects the first whose `supports(tag)` returns true, and becomes
medium-agnostic.

**`capacityBytes` is defined as the largest serialized chunk this tag can hold**,
not the medium's raw size — otherwise the two codecs would return numbers that
cannot be compared. `NdefTagCodec` derives it from `ndef.maxSize` minus the
record overhead and the terminator byte; `MifareClassicTagCodec` returns 752.
The too-small check in `startWriteSession` then becomes uniform:
`chunk.totalSize > await codec.capacityBytes(tag)`.

Routing is unambiguous because NDEF is never written onto Classic:

1. `MifareClassic.from(tag) != null` → `MifareClassicTagCodec`
2. else `Ndef.from(tag) != null` → `NdefTagCodec`
3. else → the existing `classifyNdefUnavailable` path

### Block layout

`lib/core/mifare/card_layout.dart` is a deliberate file-for-file port of
`webapp/src/mifare/card-layout.ts`: `usableBlockIndexes` (0–63, excluding block 0
and every `b % 4 == 3`), `cardCapacityBytes` = 752, `cardPayloadSize` = 720,
`chunkToBlocks()`, `firstBlockIsNfar()`, `nfarTotalLength()`.

Pure Dart with no Flutter imports, so it unit-tests without NFC hardware.

It is a **port, not a reimplementation**, and that is load-bearing: two
independent implementations of the same layout would drift, whereas a port plus
the byte-equality fixture below cannot.

### `NfcTagType` becomes medium-aware

The enum currently hardcodes an NDEF assumption — `maxPayloadSize` subtracts a
44-byte NDEF overhead that does not exist on Classic. It gains:

- a `medium` field: `TagMedium.ndef` | `TagMedium.mifareClassic`
- a new value `mifareClassic1k(name: 'Mifare Classic 1K', capacity: 752)`

For the Mifare medium `maxPayloadSize` subtracts only the 32-byte NFAR overhead,
yielding **720 — exactly the web app's `CARD_PAYLOAD_SIZE`**.

`NfcTagInfo.fromCapacity` and any other consumer that walks `NfcTagType.values`
must be checked: adding a value to that enum changes their behaviour.

### Write flow

"Mifare Classic 1K — 720 B" appears in the tag-type picker, filtered out when
the capability flag is false. On a mismatched tap the error names both sides:

> That's a Mifare Classic card, but this archive is configured for NTAG215 —
> change the tag type in Settings.

The existing Tag Too Small re-chunk dialog is untouched and continues to operate
only within NDEF tags.

A Mifare write is roughly 16 sector authentications plus 47 block writes, so the
card must be held still noticeably longer than for an NDEF write; the progress
screen says so. Every write is verified by read-back, matching the web app.

### Restore flow

Restore has no picker and routes purely on techs, via the same codec list.

This creates a case the classification added in PR #49 currently gets wrong: a
Mifare card tapped on a phone **without** NXP support exposes `NfcA` but neither
`Ndef` nor `MifareClassic`, so it would be reported as "couldn't read the tag,
try again" — inviting endless retries of something that can never succeed.

`classifyNdefUnavailable` therefore gains a third outcome, `mifareUnsupported`,
selected by this precise rule — all four conditions required:

1. `Ndef` absent, and
2. `MifareClassic` absent, and
3. `NfcA` present, and
4. the device capability flag is **false**

> This looks like a Mifare Classic card. Your phone's NFC chip can't read them.

On a device whose flag is **true**, the same tech signature means something else
(a genuinely unformatted or foreign tag), so the existing `detectionFailed` /
`notNdefFormatted` outcomes still apply there. The classifier therefore takes the
capability flag as an explicit parameter rather than reading it globally, keeping
it a pure function.

## Testing

- **`card_layout.dart` unit tests** mirroring the web app's `card-layout.test.ts`:
  block mapping, the 720/752 boundaries, final-block zero padding, NFAR probing.
- **Codec selection** tested against fake `tag.data` maps — no hardware.
- **Cross-language fixture test** extending the existing
  `tool/generate_web_fixtures.dart` / `tool/verify_web_fixtures.dart` pair to
  Mifare card images, proving Dart-written and TypeScript-written cards are
  byte-identical. This is the same mechanism that already guards the NFAR chunk
  format, and it is what makes the "port, not reimplementation" decision hold
  over time.
- **Capability detection** tested with a mocked MethodChannel.
- **Hardware validation on a real NXP phone is manual and required.** No
  simulator covers CRYPTO1.

The Flutter app currently has four test files and none covering the NFC path, so
this work also establishes that path's first tests.

## Non-goals

- iOS support — Core NFC has no CRYPTO1; permanently impossible
- Non-factory keys, key recovery, or re-keying cards
- Writing sector trailers
- Mifare Classic 4K
- NDEF-on-Mifare via the MAD/TLV layout — this design uses raw NFAR blocks
- Cross-medium re-chunking (decision 3)
- Any change to the web app, the NFAR format, or on-tag bytes
