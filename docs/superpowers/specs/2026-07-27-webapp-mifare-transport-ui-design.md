# Web App Iteration 2 — Mifare Classic Transport + Minimal UI

**Date:** 2026-07-27
**Status:** Draft for review
**Base:** branch `webapp-nfar-core-prototype` (PR #34); new branch `webapp-mifare-transport`
**Predecessor spec:** `2026-07-27-webapp-nfar-core-design.md` (its Compatibility Contract remains normative)

## Goal

Make the web core actually move chunks on and off physical Mifare Classic 1K
cards via a Chameleon Ultra over Web Bluetooth, and wrap the flow in a minimal
browser UI served on localhost. The Chameleon acts as a **reader/writer of
physical cards** (not emulation-slot storage); capacity scales with the number
of cards.

## Non-Goals

- Public hosting / PWA / service worker (iteration 3).
- Emulation-slot storage, Mifare 4K, custom sector keys (documented follow-ups).
- Web Serial / Web NFC transports.
- NDEF-on-Classic (MAD) — rejected: capacity loss and complexity for a
  compatibility benefit phones mostly can't deliver anyway.
- iOS/Safari/Firefox support — Web Bluetooth is Chromium-only.

## Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Device mode | Reader/writer of physical Mifare Classic 1K cards |
| On-card layout | Raw NFAR-native: chunk bytes sequential across data blocks; no extra framing |
| Keys | Factory (`FF FF FF FF FF FF`, key A) only in this iteration |
| Partial-write defense | Write-then-verify (read back every block, byte-compare) instead of per-block framing |
| Chunk↔card relationship | Exactly one chunk per card (mirrors one-chunk-per-tag in the Flutter app) |
| Tag arrival model | Promise-based `awaitTag()` with `AbortSignal`, not an event emitter |
| UI delivery | Localhost dev server (`npm run app`); Web Bluetooth works on localhost |
| UI stack | Vanilla TS + DOM, esbuild (dev dep) for bundling/serving; no framework |

## Card Layout

Mifare Classic 1K: 64 blocks × 16 B, sectors of 4 blocks.

- **Excluded blocks:** block 0 (manufacturer) and every sector trailer
  (`block % 4 === 3`).
- **Usable data blocks:** the 47 blocks `b ∈ 1..62` with `b % 4 !== 3` →
  752 bytes.
- **Capacity:** one NFAR chunk of ≤ 752 total bytes → max payload
  `752 − 32 = 720` bytes. `CARD_PAYLOAD_SIZE = 720` is the payloadSize the UI
  passes to `archive()`.
- **Write:** serialize chunk (`encodeChunk`), split into 16-byte blocks in
  usable-block order starting at block 1, zero-pad the final block.
- **Read:** read block 1 (contains the chunk's first 16 bytes), validate NFAR
  magic + version, take payloadSize from header offset 26 (big-endian u16) →
  total length `32 + payloadSize`; read `ceil(total/16)` usable blocks; return
  exactly `total` bytes (padding discarded). A card whose block 1 lacks the
  magic is "not an NFAR card".

## Architecture

```
webapp/
  src/
    mifare/
      card-layout.ts      # chunkBytesToBlocks() / readChunkBytesFromCard()
    transport/
      transport.ts        # Transport v2 + PresentedTag + typed errors
      mock-transport.ts   # reworked to v2 contract; insertTag() test helper
      chameleon-ble.ts    # real implementation over chameleon-ultra.js
      chameleon-device.ts # ChameleonDevice structural interface + FakeChameleon (test double lives in test/)
  app/
    index.html            # single page: Connect → Archive | Restore tabs
    main.ts               # DOM glue only (thin, untested)
    controller.ts         # DOM-free UI state machine (tested)
  HARDWARE_TESTING.md     # manual smoke checklist (first item = the BLE spike)
```

### Transport v2

```ts
export interface PresentedTag { uid: Uint8Array; capacityBytes: number }

export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Resolves when a tag enters the field. Rejects with TagTimeoutError / AbortError. */
  awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag>;
  /** Read the chunk from the current tag. */
  readChunk(): Promise<Uint8Array>;
  /** Write + read-back verify on the current tag. */
  writeChunk(bytes: Uint8Array): Promise<void>;
}
```

Breaking change to the v1 interface (`detectCapacity`, mock `presentTag`) —
v1 has no external consumers, so no compatibility shim. `MockTransport` gains
`insertTag(uid, image?)` for tests. UID (hex) is the tag identity used by the
UI to refuse writing the same card twice in one archive session and to ignore
re-scans of already-collected cards during restore.

### ChameleonBleTransport

- **Dependency:** `chameleon-ultra.js` (MIT) becomes the first **runtime**
  dependency. Constraint: it may be imported only under `webapp/src/transport/`
  and `webapp/app/`; the core (`crc32`, `chunk`, `chunker`, `crypto`, `gzip`,
  `pipeline`, `mifare/card-layout`) stays dependency-free.
- The transport takes a `ChameleonDevice` — a structural interface over the
  SDK surface we use: HF 14a scan (returns UID or none), Mifare read block,
  Mifare write block (key A, factory key). The real SDK instance satisfies it;
  `FakeChameleon` implements it over in-memory 1K card images with failure
  injection (non-factory keys, corrupt-on-write).
- `awaitTag`: poll scan every ~300 ms until a UID appears, honoring
  timeout/abort.
- `writeChunk`: write all blocks, then read each back and compare; mismatch →
  `WriteVerifyError`.
- Auth failure → `CardAuthError` ("card keys are not factory defaults").

### UI

Single page, two flows, state machine in `controller.ts` (constructor takes a
`Transport` + callbacks; no DOM imports):

- **Archive:** file picker → options (gzip checkbox, optional password) →
  `archive(data, { payloadSize: 720, … })` → shows chunk count N → loop
  "Tap card k of N": `awaitTag` → duplicate-UID guard → overwrite guard (if
  block 1 already has NFAR magic, require explicit confirm) → `writeChunk` →
  next. Cancel aborts via `AbortSignal`.
- **Restore:** scan loop: `awaitTag` → `readChunk` → `decodeChunk` → collect
  by archive ID (first card scanned fixes the session, like the Flutter
  `RestoreSession`); progress k of totalChunks; when complete → password
  prompt if encrypted flag → `restore()` → download via `Blob` +
  `<a download>`; filename entered by the user (NFAR stores no filename).
- Errors surface as plain-language messages mapped from the typed errors.

**Environment caveat (documented in HARDWARE_TESTING.md and README section):**
WSL2 has no Bluetooth — run Chrome/Edge on the Windows host against the WSL
dev server URL. Web Bluetooth requires Chromium; localhost counts as a secure
context.

## Error Types

`CardAuthError`, `WriteVerifyError`, `CardCapacityError` (chunk bytes > 752),
`TagTimeoutError`, plus DOMException `AbortError` passthrough from
`awaitTag`. All extend `Error` with `name` set, following the v1 pattern
(`NfarFormatError` etc.).

## Testing

- **card-layout unit tests:** round-trip; explicit assertions that block 0 and
  every `b % 4 === 3` block are never emitted; 720-byte payload boundary
  (752-byte chunk fits, 753 rejected with `CardCapacityError`); zero-padding
  stripped on read; non-NFAR card rejected.
- **Transport contract tests** run against both `MockTransport` and
  `ChameleonBleTransport`+`FakeChameleon`: awaitTag resolve/timeout/abort,
  write-verify failure injection, auth failure.
- **End-to-end:** archive (compressible payload, gzip+password, flag
  assertions per iteration-1 lessons) → write to ≥ 3 fake cards → shuffled
  scan incl. a duplicate scan that must be ignored → restore → byte-equal.
- **controller.ts tests:** state transitions for both flows incl. cancel and
  wrong-password retry.
- All 41 iteration-1 tests keep passing; interop fixtures untouched.
- **Hardware:** `HARDWARE_TESTING.md` manual checklist (pair, scan, one-block
  read, full archive/restore of a small file across 2 cards). Not CI.

## Risks

- **BLE pairing flakiness** (bonded PIN device) remains unvalidated until the
  hardware checklist runs — the design isolates it entirely inside
  `ChameleonBleTransport.connect()`.
- **SDK API drift:** `ChameleonDevice` is our narrow seam; if
  chameleon-ultra.js names differ from assumptions, only the adapter glue in
  `chameleon-ble.ts` changes.
- **esbuild + NodeNext interplay:** the app bundle is built by esbuild while
  tests keep using tsc output; both consume the same `.ts` sources with
  `.js`-suffixed specifiers, which esbuild handles natively.
