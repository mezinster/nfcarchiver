# Card inspector in the Flutter app (sub-project C)

**Date:** 2026-07-31
**Scope:** Sub-project **C**. Ports the web app's read-only card inspector to Flutter, available only while a Chameleon Ultra is connected.

**Depends on sub-project A** (`docs/superpowers/specs/2026-07-31-flutter-chameleon-ble-design.md`) for `ChameleonDevice` and the `supportsRawAccess` flag on `CardReader`. Nothing here can be built or tested against real hardware until A exists; the dependency-free core, however, can be written and tested first (see Sequencing).

**Goal:** Dump a presented card — identity, decoded NFAR header with CRC verification, and raw hex/ASCII per block or page — into a dismissible view that can be copied or shared, without ever writing to the card.

## Why this ports well

The web app's inspector was deliberately built as dependency-free logic behind a narrow seam, and that pays off here. `webapp/src/inspect/` is 442 lines using only language builtins, and `runInspection` talks to the UI through a six-method `InspectIO` interface rather than the DOM. That is precisely the shape that ports to Dart — and it is the same technique already proven by `lib/core/mifare/card_layout.dart`, a port of `card-layout.ts` verified byte-identical by generated fixtures.

**No new dependency is introduced by this sub-project.** Everything needed — clipboard, sharing, localisation — is already in `pubspec.yaml`. F-Droid compliance is therefore unaffected, and the risk analysis in sub-project A's spec is not reopened.

## Architecture

```
InspectScreen (Flutter)                    lib/features/inspect/presentation/
        │  reads InspectState
InspectNotifier (StateNotifier)            ← adapts callbacks to Riverpod
        │  implements InspectSink
runInspection(dev, raw, sink, token)       lib/features/inspect/domain/
        │
   ┌────┴───────────────┬──────────────┐
dumpCard()        describeNfar()    formatReport()      lib/core/inspect/
   │                                                    (dependency-free, portable)
ChameleonDevice  (from sub-project A)
```

### The portable core — `lib/core/inspect/`

Three files, ported one-for-one from `webapp/src/inspect/`, dependency-free so they run under plain `flutter test` with no widget binding:

**`card_dump.dart`** — `dumpCard(ChameleonDevice dev, DumpCallbacks cb, {CancellationToken? token})`. Scans the presented tag and routes by SAK, exactly as the TypeScript does:

| SAK | Route | Unit granularity |
|---|---|---|
| `0x08` | Mifare Classic 1K | **one unit per 16-byte block**, classified `manufacturer` (block 0), `trailer` (`block % 4 == 3`), else `data` |
| `0x00` | NTAG213/215/216 | **one unit per 4-page READ group** (a `0x30` READ returns 16 bytes), the group starting at page 0 classified `cc` — it holds UID, lock bytes *and* the capability container — every later group `data` |
| other | `UnsupportedTagError` | — |

The two media therefore have different unit sizes, both 16 bytes but meaning a block on Classic and four pages on NTAG. `DumpUnit.index` is the **starting** block or page, which is what the formatter prints.

One NTAG subtlety must survive the port, because it inverts the meaning of the same symptom: **a real READ always returns 4 pages and wraps around to page 0 near the end of memory, so a short response is legitimate only on the final group.** Anywhere else a short read means marginal RF coupling and is recorded as a `shortRead` failure. The web app's comment records that `FakeChameleon` does not wrap, which is why the fake and real device disagree here — the Dart fake must reproduce that same non-wrapping behaviour or the final-group branch goes untested.

A `DumpUnit` carries `index`, optional `sector`, `kind`, and **either** `bytes` **or** a `failure` of `authFailed`, `notRead`, or `shortRead`. That either/or is the design's core idea: a sector whose key is unknown is *reported*, not fatal. `DumpResult` additionally carries `aborted` and `cardLost` so a partial dump is still a usable artefact.

**`nfar_describe.dart`** — `describeNfar(Uint8List data, {int? capacityBytes})` returning a sealed `NfarDescription` of `NfarAbsent(reason)` or `NfarPresent(version, flags, compressed, encrypted, archiveId, chunkIndex, totalChunks, payloadSize, totalLength, crcStored, crcComputed, crcValid, warnings)`.

**This function must stay deliberately more tolerant than `Chunk.fromBytes`.** Where the production decoder throws, `describeNfar` reports — in an inspector, the malformed header *is* the information. A port that reuses the production decoder would defeat the feature's purpose. `crcStored`/`crcComputed`/`crcValid` are nullable precisely because a truncated chunk has no CRC to compare.

**`hex_view.dart`** — `formatUnitRow`, `formatIdentity`, `formatNfar`, `formatReport`. Pure string formatting, which makes it the easiest thing in the project to verify across languages.

### The identity probe

`diagnose_card.dart` ports `webapp/app/diagnostics.ts`: a raw anticollision exchange producing `CardDiagnosis` — ATQA, cascade-level-1 UID bytes, the BCC the card returned versus the BCC we compute, whether they agree, and whether the tag is a cascade (7-byte UID).

Its value is catching cards that lie: a self-inconsistent BCC means a malformed or "magic" card, which is exactly what someone reaches for an inspector to find out.

It takes the narrow `RawAntiColl` seam (a single `transceive`), satisfied by `ChameleonDevice.transceive14a`. Keeping it narrow is deliberate — the probe needs raw frames, not the full device.

### `InspectSink` — the UI seam

The web app's `InspectIO` has six methods and is what lets `runInspection` be tested without a DOM stub. The Dart equivalent keeps that shape:

```dart
abstract class InspectSink {
  void setIdentity(String text);
  void setNfar(String text);
  void appendRow(String line);
  void setProgress(String text);
  void setReport(String text);
  void setStatus(String text);
}
```

**Callbacks rather than a `Stream<InspectEvent>`.** A stream is the more idiomatic Dart shape and would compose with `StreamBuilder`, but it is the wrong choice twice over: it diverges from the TypeScript this is ported from, making future cross-porting harder for no gain, and it diverges from this app's own convention — `NfcRepository` already drives every session through `onTagDiscovered` / `onChunkRead` / `onError` callbacks. `InspectNotifier` implements `InspectSink` and exposes Riverpod state, so the idiomatic surface exists where Flutter wants it, one layer up.

### Superseded inspections must not write to the UI

The web app hit this and fixed it in commit `67c4683` (*"epoch-guard InspectIO callbacks against superseded inspections"*). The failure: a second inspection starts while the first is still draining, and the first one's late callbacks scribble its rows and progress into the second one's view.

`runInspection` therefore takes a cancellation token, and **`InspectNotifier` checks token ownership inside every `InspectSink` method** — not merely at the start of the run. A guard placed only at the entry point does not help, because the damage is done by callbacks already in flight.

This is the same rule stated three times elsewhere in this project (`readerEpoch` in `device.ts`, the ownership guard in `browser-ndef-io.ts`, and `ReaderLock.release` being owner-checked): **a superseded operation may only touch state it still owns.**

Dart has no `AbortSignal`, so a minimal `CancellationToken` (a `cancel()` and an `isCancelled` flag, plus a `Future` for awaiting) is defined in `lib/core/inspect/` alongside the dump. It is deliberately not a new dependency.

## User interface

A full-screen dialog reached from the reader/device bar, mirroring the web app's modal:

- **Identity** — medium, SAK, UID, and the anticollision diagnosis, with a clear marker when the BCC is inconsistent.
- **NFAR chunk** — the decoded header, or the reason none was found. CRC validity is the headline: valid, invalid, or not computable.
- **Raw** — one monospace row per block/page, appended live as the dump progresses, with failures shown in place (`auth failed`, `not read`, `short read`) rather than omitted.
- **Progress** — `n / total`, since a 64-block Classic dump over BLE is not instant.
- **Actions** — Copy, Share, Close.

**Availability.** The entry point is enabled only when the active `CardReader` reports `supportsRawAccess == true` — i.e. a connected Chameleon. Under phone NFC it is visible but disabled, with a tooltip explaining why, matching the web app's `inspectNeedsChameleon` treatment. It is never hidden, because a silently absent control teaches the user nothing.

**Read-only.** The inspector never writes. It uses `ChameleonDevice` directly rather than going through `CardReader`'s session/write API — a raw dump is not a chunk operation, and routing it through the write path would be both wrong and dangerous.

### Copy and Share

- **Copy** → `Clipboard.setData` with the full report text.
- **Share** → `share_plus` writing the report to a temporary `.txt` file. **The `Share.shareXFiles` call must carry an explicit MIME type** resolved via `lookupMimeType()`, per the rule in `CLAUDE.md`: without it Android's `ContentResolver` reports `application/octet-stream` and strict apps (Telegram among them) refuse to send. A UTF-8 report shared as octet-stream is also the exact class of bug seen in the web app, where an untyped `Blob` left Android's viewer guessing the charset.

## Localisation

The dialog's **chrome is localised** — title, section headings, button labels, the disabled-state tooltip, progress wording — added to `app_en.arb` and all six translation files, per `CLAUDE.md`.

The **report body stays English**, matching the deliberate decision recorded in `CLAUDE.md` that log entries and the card-inspection report are not translated. The report is diagnostic output meant to be pasted into a bug report or forum post, where a Georgian-localised hex dump helps nobody. This is a decision, not an omission, and the spec states it so a reviewer does not "fix" it.

## Testing

**Unit, no hardware, no widgets:**
- `describeNfar` against a valid chunk, a truncated header, a CRC mismatch, a bad version, and an empty card — the tolerance cases are the point, so each must assert a *reported* description rather than a thrown exception.
- `formatUnitRow` / `formatIdentity` / `formatNfar` / `formatReport` on fixed inputs.
- `dumpCard` against a `FakeChameleonDevice` (from sub-project A) for: a full Classic dump, a Classic with one sector auth-failing, an NTAG dump, an unsupported SAK, cancellation mid-dump, and a card removed mid-dump (`cardLost`).
- `CancellationToken` ownership: a superseded run's callbacks are dropped. **This is the regression test for `67c4683` and must assert that late callbacks from run 1 do not mutate run 2's state** — not merely that cancellation sets a flag.

**Cross-language fixtures.** `formatReport` output is a pure function of the dump, so the TypeScript generates a fixture report from a fixed synthetic card and the Dart test asserts byte-equality. This is the same technique as `tool/generate_mifare_fixtures.dart`, and it is the strongest available evidence that the port is faithful rather than merely plausible.

**Not testable without hardware, and stated as such:** that a real card's anticollision returns the expected ATQA/BCC, that auth failures on a real foreign card surface as `authFailed` rather than an exception, and that a 64-block dump completes over BLE within a tolerable time.

## Sequencing

The dependency-free core (`lib/core/inspect/`) depends only on the `ChameleonDevice` *interface*, not its BLE implementation. It can therefore be written, ported and fully unit-tested against `FakeChameleonDevice` **before** sub-project A's BLE layer works on hardware — and doing so is recommended, because it turns the riskiest part of A (the wire protocol) into the only unknown left when the two meet.

The UI layer must wait for A, since there is nothing to inspect without a connected reader.

## Non-goals

- **Writing, formatting, or key recovery.** Read-only, factory keys only, and no attempt to crack a sector whose key is unknown — an auth failure is reported and the dump continues.
- **Inspection over phone NFC.** `nfc_manager` exposes no raw anticollision or arbitrary block access; this is a permanent limitation, not a deferred feature.
- **Sector trailer writes**, or anything that could brick a card. The dump reads trailers and displays them; it never modifies one.
- **Translating the report body** (see Localisation).
- **Firmware/DFU interaction**, matching sub-project A.
- **Exporting a re-flashable dump format** (e.g. `.mfd`/`.bin` for other tooling). The report is a human-readable diagnostic. A binary export is a plausible future feature and is explicitly out of scope here.

## Risks

- **Untestable-without-hardware surface is larger here than in A.** A protocol frame either decodes or does not; a card dump's correctness depends on real card behaviour — cascade UIDs, unreadable sectors, cards pulled mid-dump.
- **A 64-block Classic dump over BLE may be slow enough to feel broken.** The progress callback exists for this, but the acceptable duration is unknown until measured on hardware, and the design does not guess at it.
- **The tolerance of `describeNfar` is easy to erode.** A future refactor that "simplifies" it to reuse `Chunk.fromBytes` would silently destroy the feature's value, since malformed input would then throw instead of being described. The tests named above are the guard, and the reason is documented here so the guard is understood rather than deleted.
