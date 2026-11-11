# Mifare Classic 4K support — design

Date: 2026-11-11 · Scope: Flutter app and web app (`webapp/`)

## Intent

NFC Archiver stores one NFAR chunk per card. Mifare Classic 1K holds 752 B of
raw chunk (47 usable blocks); a Mifare Classic 4K holds 3,440 B (215 usable
blocks) — about 4.6× more, so far fewer cards per archive.

This is **proactive work**: nobody on the project has a 4K card yet. The code
should be complete and tested against simulated cards, so that the day someone
holds a real 4K card, verifying it is a matter of flipping a switch and
tapping — not a development project.

## Decisions made by the maintainer

1. **Writing 4K stays hidden from users until it is verified on a real card.**
2. **The unlock is a hidden developer switch inside the normal release app**
   (no special build), so whoever first has 4K cards can test on a TestFlight /
   Play / F-Droid build or the live web app.
3. **Both the Flutter app and the web app** get 4K, behind the same kind of
   switch.

## Goals

- Write and read NFAR chunks on Mifare Classic 4K cards through:
  - the Chameleon Ultra (Flutter app on Android and iOS; web app), and
  - the phone's own radio on Android phones with Mifare support.
- Dart and TypeScript produce byte-identical 4K card images, proven by fixtures
  the same way 1K is today.
- The card inspector (web app `src/inspect/`, Flutter `lib/features/inspect/`)
  can dump a 4K card — this is the main tool for the first hardware check. The
  Flutter inspector is Chameleon-only and hardcodes the 1K capacity cap in
  `run_inspection.dart`; it must use the per-card capacity.
- A clear, repeatable hardware-verification checklist, so "tested on real
  hardware" has a definite meaning (see the end of this document).

## Non-goals

- Mifare Classic **2K** (32 sectors) and **Mini** (5 sectors). Not offered, not
  detected as their own type. *(Builder's call whether a 2K card is simply
  treated as 1K for the first 16 sectors; it must not be offered as a medium.)*
- iOS phone radio: Core NFC has no CRYPTO1, so Mifare of any size stays
  impossible there. On iOS, 4K works only through the Chameleon — same as 1K.
- Web NFC (Chrome on Android): NDEF-only, no Mifare at all. Unchanged.
- Non-factory keys, writing sector trailers, MAD / NDEF-on-Classic formatting.
  **Sector trailers are never written** — the existing rule holds for 4K.
- Any change to the NFAR format. A 4K chunk is an ordinary NFAR chunk with a
  larger payload (max 3,408 B, well under the 65,535 B the header allows).
- Turning 4K on for everyone. That is a later, one-line release once the
  checklist passes.

## Anti-goals (would make this a failure even if it "works")

- **Any change to what is written on a 1K card**, or to how existing 1K cards
  read. 1K archives already in users' hands must keep working byte-for-byte.
- 4K **writing** reachable by an ordinary user with the switch off — including
  indirectly, e.g. the web app's "Auto-detect" target sizing chunks for 4K
  because a 4K card was tapped first.
- A half-written card from a sector that rejects the factory key. On the
  Android phone radio, `MifareTagCodec.writeChunk` already authenticates every
  sector it will touch before writing the first block; 4K inherits that. The
  Chameleon paths (Flutter `ChameleonReader._writeClassic`, web
  `ChameleonBleTransport.writeChunk`) send the key with every block command and
  have no such pass today. **My call:** add a pre-check pass — one factory-key
  read per touched sector before the first write — **for 4K-sized writes only**
  (chunks > 752 B). 1K writes through the Chameleon stay exactly as they are
  (no extra round trips, no new failure mode), consistent with the first
  anti-goal.
- Breaking the dependency fence (`chameleon-ultra.js` imported only where it is
  today) or the web core's dependency-free rule.

## Card layout (the core of the design)

### Geometry

A 4K card has 256 blocks of 16 B in 40 sectors:

- sectors 0–31: 4 blocks each (blocks 0–127), trailer is the last block of each;
- sectors 32–39: 16 blocks each (blocks 128–255), trailer is the last block of
  each (blocks 143, 159, …, 255).

Usable blocks = every block except block 0 (manufacturer) and every sector
trailer: 95 + 120 = **215 blocks = 3,440 B**, payload **3,408 B**.

### The 4K layout is a strict extension of the 1K layout

The usable-block order is ascending block index. The first 47 entries of the 4K
list are exactly the 1K list (sectors 0–15 have the same geometry on both
cards). Consequences, all intended:

- A chunk of ≤ 752 B written to a 4K card is byte-identical to the same chunk
  on a 1K card. Writing a 1K-sized archive onto 4K cards is fine and needs no
  switch — this is what Android's phone radio already does today, untested; it
  becomes deliberate and tested.
- Reading needs no layout choice: read blocks in list order until the NFAR
  header's declared length is satisfied. The only per-card fact is the
  **capacity cap** (752 or 3,440 B) used to reject a corrupt length.

So instead of a second layout, the shared layout module exposes one ordered
usable-block list for 4K (whose 1K prefix is today's list), a capacity per card
size, and a `sectorOf(block)` that is correct for both geometries:
`block < 128 ? block ÷ 4 : 32 + (block − 128) ÷ 16`. Today's codec computes
the sector as `block ~/ 4`, which is wrong above block 127 and must go.

Dart (`lib/core/mifare/card_layout.dart`) and TypeScript
(`webapp/src/mifare/card-layout.ts`) stay deliberate ports of each other —
same constants, same ordering, "change both or neither".

### Interop proof

Extend `tool/generate_mifare_fixtures.dart` to also emit a 4K card image for a
chunk larger than 752 B (so blocks above 63, including sectors 32+, are
exercised), and the web app's `interop-dart.test.ts` to assert byte equality.
The existing 1K fixture must be regenerated **unchanged** — that is the
regression proof for the first anti-goal.

## Detecting a 4K card

| Path | Signal |
|---|---|
| Chameleon (Flutter `ChameleonReader`, web `AutoTransport`, both inspectors) | SAK in {`0x18`, `0x38`, `0x98`} = Mifare Classic 4K (today only `0x08` = 1K and `0x00` = NTAG are accepted) |
| Android phone radio (`mifareIoFor` / `MifareTagCodec`) | `MifareClassicAndroid.size == 4096` (equivalently `sectorCount == 40`); 1K is `size == 1024` |

**SAK set — my call.** Per NXP AN10833, `0x18` is genuine 4K, `0x38` is 4K
emulated by SmartMX/JCOP, `0x98` is a Gemplus 4K. All three expose the 4K
Classic block map, so all three are 4K; this keeps the first hardware check from
failing just because the card bought is an emulated one. The 1K match stays
`0x08` only (widening it is out of scope). Mifare 2K (`0x19`), Mini (`0x09`)
and anything else stay "Unsupported tag". The SAK is logged at info level on
every tap, so a hardware tester can report an unexpected value from the
diagnostics log. One shared classifier per language (`sak → 1K | 4K | NTAG |
unsupported`) replaces the scattered `== 0x08` checks.

Every place that branches on SAK `0x08` today must use that classifier; in the Flutter
`ChameleonReader` that is at least the write path, `_readChunkBytes` and
`_tagInfo`. The `MifareBlockIO` seam grows whatever it needs to report the
card size (so the codec stays testable without hardware).

## The developer switch

Hidden by default, persisted per device, off unless deliberately turned on.

- **Flutter app:** tapping the home-screen version footer 7 times reveals a
  "Developer options" entry (my call: in the About area, next to Diagnostics
  log). It holds one toggle, "Mifare Classic 4K (experimental, unverified)".
  Stored with `shared_preferences` (already a dependency). Exposed as a
  Riverpod provider.
- **Web app:** tapping the version line in the About panel 7 times reveals the
  same toggle; stored in `localStorage` (as theme and locale already are).
- The toggle and its label are localized in all 7 languages in both apps (the
  repo rule for UI strings). The reveal can show a short "Developer options
  enabled" confirmation.
- Turning 4K on for everyone later = defaulting the flag to on (or removing it)
  in a release. The switch itself can then be deleted.

### What the switch gates — and what it doesn't

| Behaviour | Switch off | Switch on |
|---|---|---|
| "Mifare Classic 4K" offered in the tag-type list | no | yes (when the active reader supports Mifare, same rule as 1K) |
| Chunk sizing for a tapped 4K card (web "Auto-detect", Flutter detected-capacity paths) | treated as 1K: 720 B payload | 3,408 B payload |
| Writing a ≤ 752 B chunk to a 4K card | allowed (byte-identical to 1K) | allowed |
| **Reading** a chunk from a 4K card, any length | allowed | allowed |
| Inspecting a 4K card | allowed | allowed |

Reading and inspecting are ungated: the code only runs when a 4K card holding
NFAR data is presented, it is read-only, and it is exactly what the first
hardware check needs.

## Tag type and sizing (Flutter)

- New `NfcTagType.mifareClassic4k` (`capacity: 3440`, `medium:
  TagMedium.mifareClassic`). `selectableTagTypes` gains the switch as an input
  alongside `mifareAvailable`; it remains a pure, tested function.
- Selection reset: like today's rule that resets Mifare to NTAG216 when the
  reader stops supporting Mifare, a 4K selection resets (to Mifare Classic 1K
  if the reader supports Mifare, else NTAG216) when the switch is turned off.
- `MifareTagCodec.capacityBytes(tag)` returns the real card's capacity
  (752 or 3,440) instead of a constant.
- **Re-chunk for a too-small card must become medium-aware.** Today
  `NfcTagType.maxPayloadForCapacity` subtracts NDEF overhead, and the comment
  in `nfc_repository.dart` (Mifare "too small" branch) records that this gives
  680 instead of 720 for a 1K card and that the branch was unreachable. With
  4K selected and a 1K card tapped it becomes reachable, so the dialog in
  `write_progress_screen.dart` must compute a Mifare payload as
  `capacity − 32` (header + CRC) and an NDEF payload as today. The same fix
  applies to `ArchiveNotifier.rechunkForDetectedCapacity`
  (`archive_provider.dart`), which also calls `maxPayloadForCapacity`, and to
  the Chameleon write path, which currently compares against the 1K constant.
- Re-chunking keeps today's limit: only before the first card of an archive is
  written. A smaller card later in the archive gets the existing "too small"
  error; that is unchanged.
- Mixed cards within one archive follow existing behaviour: chunk size is
  fixed per archive; a too-small card triggers the existing re-chunk offer.

## Web app specifics

- `#target-tag` gains a "Mifare Classic 4K — 3,440 B" option, hidden unless
  the switch is on, and disabled under Web NFC exactly like the 1K option
  (`syncTargetTagForReader`).
- The Classic transport reports `maxChunkPayload` per tapped card: 720 for 1K;
  for 4K, 3,408 only when the switch is on, otherwise 720. Because the
  controller already re-chunks to the tapped card's `maxChunkPayload`, this one
  rule covers both the explicit selection and "Auto-detect".
- `FakeChameleon` simulates a 4K card (SAK `0x18`, 256 blocks, factory-keyed
  trailers at the right positions, including the 16-block sectors) so transport,
  orchestrator and inspector tests cover it without hardware.

## Testing

All without hardware, mirroring how 1K is tested today:

- layout: block list, capacities, `sectorOf` for both geometries (trailers at
  3, 7, …, 127, then 143, 159, …, 255 are never in the list);
- Dart ↔ TypeScript fixture equality for 4K; 1K fixture unchanged;
- codec / reader / transport: write-then-read round trips on simulated 4K
  cards (Flutter fake Chameleon device and a fake `MifareBlockIO` reporting
  4096; web `FakeChameleon`), pre-auth covering sectors 32–39, a chunk
  ≤ 752 B written to 4K equals the 1K image;
- gating: with the switch off, 4K is not selectable and a tapped 4K card is
  sized at 720 B (including web Auto-detect); with it on, 3,408 B;
- re-chunk: 4K selected + 1K card offers a 720 B payload (not 680);
- inspectors dump a simulated 4K card;
- l10n completeness for the new strings (existing tests in both apps).

## Hardware verification checklist (what "tested on real hardware" means)

Switch on, with a real Mifare Classic 4K card (factory keys):

1. Inspector (web app via Chameleon): card identified as 4K, all 256 blocks
   dumped, trailers untouched.
2. Write a multi-card archive sized for 4K through the Chameleon, restore it
   (web app, and Flutter app on iPhone or Android).
3. Same through an Android phone's own radio, if a Mifare-capable phone is at
   hand.
4. Mixed, first card of the archive: 4K selected, tap a 1K card first →
   Flutter offers a re-chunk at 720 B; the web app (which has no offer)
   silently re-sizes the archive to 720 B, as it already does for any first
   card. Finish the archive and restore it.
5. Note the time to write one full 4K card over the Chameleon (215 blocks, each
   written and read back) — if it is long enough that holding the card is
   awkward, that is a follow-up, not a blocker.
6. Re-inspect the card after writing: every sector still opens with the
   factory key.

When it passes, a release turns 4K on for everyone and fastlane changelogs
mention it.

## Left to the builder

- Exact names and module structure, provided Dart and TypeScript layout
  modules stay mirror images.
- How the inspectors render 40 sectors of differing size.
- Whether a stray Mifare 2K card is handled as 1K or rejected (it must not be
  offered or sized as 4K).
- Wording of the experimental label and confirmation, within the l10n rules.
