# Web App Iteration 3 — Filename Preservation, Text Mode, Multi-Archive Restore

**Date:** 2026-07-28
**Status:** Draft for review
**Base:** branch `webapp-metadata-features` (off `webapp-nfar-core-prototype`, PR #34)
**Predecessor specs:** `2026-07-27-webapp-nfar-core-design.md`, `2026-07-27-webapp-mifare-transport-ui-design.md` (their contracts remain normative)

## Goal

Bring three metadata/UX features from the Flutter app to the web app, matching
Android's on-tag formats so archives are interoperable between phone and browser:

1. **Filename preservation** — the original filename travels inside the archive
   and is recovered on restore.
2. **Text mode + live card counter** — archive typed text, with a live estimate
   of how many cards it will take.
3. **Multi-archive restore (pick-to-restore)** — scanning a mixed pile of cards
   detects every distinct archive (with its encryption status and completeness);
   the user picks one to restore.

## Non-Goals

- No change to the proven core (`crc32`, `chunk`, `chunker`, `crypto`, `gzip`,
  `pipeline`, `mifare/card-layout`) — all new logic sits in the app/controller
  layer, exactly as Android keeps the filename wrapper in its repository above
  the core services.
- No custom sector keys, emulation slots, hosting/PWA (still deferred).
- No hardware-only behavior; everything is testable against `MockTransport` /
  fixtures. Real-device validation stays in `HARDWARE_TESTING.md`.

## Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Filename wrapper bytes | **Match Android exactly** for phone↔web interop |
| Card counter | **Live and compression-accurate** (actually gzips the wrapped input) |
| Scope | All three features this round; filename wrapper is the shared foundation |
| Inspector | **Integrated into Restore** as multi-archive detection + pick-to-restore (not a separate flow) |

## Feature 1 — Filename Wrapper

### Format (verbatim from the Flutter app)

`lib/features/archive/data/archive_repository.dart` (`_prependFilenameMetadata`)
and `lib/features/restore/data/restore_repository.dart`
(`_extractFilenameMetadata`):

```
[ 2-byte length, big-endian ][ UTF-8 filename bytes (1..255) ][ original data ]
```

Pipeline order (Android and web must match):
- **Archive:** `wrap(data, fileName)` → compress-if-smaller → encrypt-if-password → chunk.
- **Restore:** assemble → decrypt → decompress → `unwrap` → `(fileName, data)`.

The filename is inside the compressed+encrypted payload, so it is on the tags,
protected by the password, and recoverable from a cold scan.

### Module — `webapp/src/filename.ts` (pure, dependency-free)

- `wrapWithFilename(data: Uint8Array, fileName: string): Uint8Array` — UTF-8
  encode, truncate to 255 bytes, prepend 2-byte big-endian length.
- `unwrapFilename(data: Uint8Array): { fileName: string | null; data: Uint8Array }`
  — Android's validation: return `{ fileName: null, data }` (data used as-is)
  when `length < 2`, `filenameLength === 0`, `filenameLength > 255`,
  `data.length < 2 + filenameLength`, or the bytes are not valid UTF-8.

### Placement

- `ArchiveController.prepare({ data, fileName, compress, password })` calls
  `wrapWithFilename` before `archive()`.
- `RestoreController.restore(...)` (see Feature 3) calls `unwrapFilename` after
  `restore()` and returns `{ data, fileName }`.

## Feature 2 — Text Mode + Live Card Counter

- The Archive UI gains a **textarea**. If text is present and no file is chosen,
  it is archived as UTF-8 bytes with filename `text_note.txt` (Android's
  default), which the user may edit.
- **Live counter** — `estimateCardCount(data, fileName, { compress, encrypted })`
  in `webapp/app/estimate.ts` (pure, DOM-free, unit-tested):
  1. `wrapped = wrapWithFilename(data, fileName)`
  2. `processed = compress ? (gzip(wrapped) if smaller else wrapped) : wrapped`
  3. `size = processed.length + (encrypted ? ENCRYPTION_OVERHEAD /*44*/ : 0)`
  4. `return size === 0 ? 0 : Math.ceil(size / CARD_PAYLOAD_SIZE /*720*/)`
- The UI shows `≈ N card(s)`, debounced (~200 ms) on text/compress/password
  changes. `encrypted` = the password field is non-empty (encryption adds a
  fixed 44 bytes regardless of the password value).

## Feature 3 — Multi-Archive Restore (Detection + Pick-to-Restore)

Mirrors Android's `RestoreSessionInfo` model (`archiveId`, `receivedCount`,
`totalChunks`, `isEncrypted`) and its "multiple archives detected → select one"
flow. This replaces the current single-archive restore (the
`WrongArchiveError` rejection is superseded by grouping).

### Controller — reworked `RestoreController`

Internal state: `Map<archiveIdHex, { archiveId: Uint8Array; totalChunks: number; flags: number; chunks: Map<number, Chunk>; uids: Set<string> }>`, plus a global `seenUids: Set<string>`.

- `scanNextCard(signal?): Promise<DetectedArchive[]>` — `awaitTag`; if the UID
  was already seen, return the current snapshot without reading; otherwise
  `readChunk` → `decodeChunk`, file the chunk under its `archiveId` group
  (idempotent by `chunkIndex`), record the UID, and return the snapshot. Header
  decode only — never decrypts.
- `detectedArchives(): DetectedArchive[]` — snapshot for the UI.
- `restore(archiveId: string, password?): Promise<{ data: Uint8Array; fileName: string | null }>`
  — assemble that archive's chunks (`NfarAssemblyError` if any index is
  missing), then decrypt (`PasswordRequiredError` if encrypted with no password,
  `DecryptionError` if wrong) → decompress → `unwrapFilename`.

```ts
interface DetectedArchive {
  archiveId: string;   // full UUID, 8-4-4-4-12
  shortId: string;     // first 8 hex chars, for compact display
  totalChunks: number;
  received: number;    // distinct chunk indices collected
  isEncrypted: boolean;
  isCompressed: boolean;
  complete: boolean;   // received === totalChunks
}
```

`formatArchiveId(id: Uint8Array): string` (new helper) produces the Android UUID
string. `isEncrypted`/`isCompressed` derive from the chunk `flags`
(`FLAG_ENCRYPTED` 0x02, `FLAG_COMPRESSED` 0x01).

### UI

Restore becomes a scan-then-pick flow:
- **Scan cards** starts a detection loop (`AbortController`), rendering a live
  list of detected archives:
  ```
  Archive a1b2c3d4…   🔒 encrypted   ·   2 / 3 cards        [Restore]
  Archive 9f0e1122…   unencrypted    ·   1 / 1 card ✓       [Restore]
  ```
  `TagTimeoutError` inside the loop just re-awaits (keep scanning).
- Each **complete** archive's `[Restore]` button is enabled. Clicking it aborts
  the scan, prompts for a password if `isEncrypted` (with wrong-password retry),
  calls `controller.restore(id, pw)`, and downloads the result named after the
  recovered filename (falling back to `restored.bin`).
- A **Stop** control ends scanning without restoring.

## Restore Filename UX

The download name is the recovered filename when present; otherwise the "save
as" field value or `restored.bin`. When a filename is recovered, it also
populates the "save as" field for visibility.

## New / Changed Files

- Create: `webapp/src/filename.ts`, `webapp/app/estimate.ts`
- Create tests: `webapp/test/filename.test.ts`, `webapp/test/estimate.test.ts`
- Modify: `webapp/app/controller.ts` (ArchiveController.prepare wraps; RestoreController reworked to multi-archive), `webapp/app/main.ts` + `webapp/app/index.html` (textarea, card counter, scan-then-pick restore UI), `webapp/src/chunk.ts` or a small util for `formatArchiveId`
- Modify tests: `webapp/test/controller.test.ts`
- Interop: extend `tool/generate_web_fixtures.dart` (emit a filename-wrapped, compressed+encrypted archive via the app's `createArchiveFromBytes` path) and `webapp/test/interop-dart.test.ts` (restore it, assert recovered filename + data); extend `webapp/test/write_ts_fixtures.ts` + `tool/verify_web_fixtures.dart` for the reverse direction.

## Error Handling

Reuse existing typed errors (`PasswordRequiredError`, `DecryptionError`,
`NfarAssemblyError`, `TagTimeoutError`, `CardAuthError`). `WrongArchiveError`
is removed (multi-archive detection makes mismatched cards expected, not an
error). New human messages for the detection/selection states.

## Testing

- `filename.test.ts` — wrap/unwrap round-trip; exact-bytes assertion for a known
  name; each invalid case (len 0, len > 255, truncated, bad UTF-8) → null +
  original data.
- `estimate.test.ts` — counts for uncompressed / compressed / encrypted; the
  720-byte boundary (752-byte chunk → 1 card, +1 byte → 2); empty input → 0.
- `controller.test.ts` — prepare wraps the filename; restore of a selected
  archive unwraps and returns the name; multi-archive detection groups by
  archiveId and dedups by UID; restoring an incomplete archive throws;
  encrypted archive demands the password.
- **Cross-language interop (headline):** a Dart-created filename-wrapped,
  compressed+encrypted archive restores on the web with the **filename
  recovered**, and a web-created one is unwrapped by the Dart verifier — proving
  archive-on-phone / restore-in-browser works, filename and all. (gzip
  cross-decompresses even though compressed bytes differ, per iteration 1.)
- All existing tests continue to pass; the core and its interop fixtures are
  untouched.

## Risks

- **Behavior change:** every web archive now carries the wrapper (as every
  Android archive already does). Pre-wrapper web test archives would restore
  with a small garbage prefix — acceptable (throwaway test cards); everything
  going forward is wrapped and interoperable.
- **Restore UI complexity** grows (dynamic per-archive list + abortable scan).
  Kept out of the tested controller; `main.ts` stays thin glue over the
  controller's `detectedArchives()` / `restore()`.
- **Fixture fidelity:** the interop fixture must use Android's real wrapper +
  pipeline (`createArchiveFromBytes`), not a re-implementation, so a format drift
  can't hide.
