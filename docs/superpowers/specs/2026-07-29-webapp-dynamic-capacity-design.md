# Web App Dynamic Chip-Capacity Re-chunking — Design

**Status:** approved (brainstorm) — 2026-07-29

**Goal:** Make archiving adapt to the **actual** memory of the tapped NFC chip instead of trusting the target-tag dropdown, so a card smaller than the selected type no longer fails with `CardCapacityError`. On the first tap the archive auto-re-chunks to fit the real card; the dropdown becomes an estimate hint with an Auto-detect default.

## Motivation

`ArchiveController.prepare()` chunks the data once, up front, using the `payloadSize` derived from the **target-tag dropdown**. `writeNextCard()` then writes those pre-sized chunks and never inspects the tapped card's real capacity — even though the transport already provides it. So selecting NTAG216 (812 B/chunk) and tapping a smaller NTAG213/215 makes `writeChunk` reject the oversized chunk with `CardCapacityError`, surfaced as the misleading *"This is too large for the selected tag — pick a larger tag type."* (`app/ui/errors.ts:11`).

The Flutter app already solves this with `ArchiveNotifier.rechunkForDetectedCapacity()` → `ArchiveRepository.rechunkForCapacity()`, which re-splits the already-processed payload to the detected capacity, **only before any chunk is written** (re-chunking after cards exist would invalidate their `totalChunks`/index headers). This design ports that behavior to the web app.

## Decisions (locked during brainstorming)

1. **Auto-rechunk + status note.** On the first tap, silently re-chunk to fit the real card and show a status line; no dialog. Safe because re-chunk only happens before any write.
2. **Dropdown = estimate hint, with an Auto-detect default.** The dropdown only sizes the `≈ N cards` preview; the real chunking is decided by the tapped card.
3. **Independent of PR #38 (Log tab).** This iteration branches off `master` and does **not** depend on the logger from `feat/webapp-log-tab`. The re-chunk is surfaced via the archive status line only. (A `log.info('archive','Re-chunked',…)` can be added as a one-line follow-up once PR #38 merges.)

## Core invariant

Each NFAR chunk header carries `totalChunks` and the chunk's index. Re-chunking changes both, so it is only valid **before the first card is written**. The first tapped card therefore *commits* the layout; subsequent cards must fit it. Re-chunking re-splits `assembleChunks(this.chunks)` (the already compressed+encrypted payload) — it never re-runs `archive()`, so the ciphertext and `archiveId` are unchanged; only the number/size of chunks differs.

## Architecture

### 1. Transport exposes the real per-card chunk-payload capacity (`src/transport/transport.ts` + implementations)

`PresentedTag` gains one field:

```ts
export interface PresentedTag {
  uid: Uint8Array;
  capacityBytes: number;    // raw user memory (unchanged; informational)
  maxChunkPayload: number;  // NEW: max NFAR chunk-payload this card holds
}
```

`maxChunkPayload` is what the chunker needs (the value the dropdown's `payloadSize` represents), which each transport already computes internally:

- `ChameleonBleTransport.awaitTag` → `maxChunkPayload: CARD_PAYLOAD_SIZE` (720) (`src/mifare/card-layout.ts`).
- `NtagTransport.awaitTag` → `maxChunkPayload: ntagChunkPayloadSize(detectedType)` (73/428/812) (`src/nfc/type2.ts`). The type is already detected there via `GET_VERSION`.
- `AutoTransport.awaitTag` returns the chosen delegate's `PresentedTag` unchanged, so the field passes through.
- `MockTransport` gains a settable `maxChunkPayload` (constructor option or setter; default `CARD_PAYLOAD_SIZE` = 720) so tests can simulate a small card.

`capacityBytes` is retained (informational, no current consumer depends on it as a payload size).

### 2. Auto-rechunk in `ArchiveController` (`app/controller.ts`)

- `prepare()` stores the payload size it chunked with: add a private `private payloadSize = 0;` set to `req.payloadSize` in `prepare`.
- New method:

```ts
/** Re-split the already-processed payload to a new per-card size, preserving the
 *  archiveId (no re-encrypt). Only valid before any card is written. Returns the
 *  new chunk count. Throws if a card has already been written. */
rechunkForCapacity(newPayloadSize: number): number {
  if (this.written > 0) throw new RechunkTooLateError('Cannot re-chunk after writing has started');
  const payload = assembleChunks(this.chunks);
  const { flags, archiveId } = this.chunks[0]!;
  this.chunks = createChunks(payload, newPayloadSize, flags, archiveId);
  this.payloadSize = newPayloadSize;
  return this.chunks.length;
}
```

- `writeNextCard()` — after `awaitTag`, before the overwrite check / `writeChunk`, auto-rechunk on the first fitting tap:

```ts
const tag = await this.transport.awaitTag({ signal });
const key = uidHex(tag.uid);
if (this.writtenUids.has(key)) return { done: false, progress: this.progress(this.written) };

let rechunkedTo: { total: number; payloadSize: number } | undefined;
if (this.written === 0 && tag.maxChunkPayload !== this.payloadSize) {
  const total = this.rechunkForCapacity(tag.maxChunkPayload);
  rechunkedTo = { total, payloadSize: tag.maxChunkPayload };
}
// … existing overwrite check + writeChunk(this.chunks[this.written]) …
return { done, progress: this.progress(...), ...(rechunkedTo ? { rechunkedTo } : {}) };
```

The return type gains an optional `rechunkedTo?: { total: number; payloadSize: number }`. `createChunks` throws `RangeError` if the data would exceed `MAX_CHUNKS` for a tiny card — that propagates as a normal archive error (the panel surfaces "file too large even for this card").

New error type `RechunkTooLateError` (in `app/controller.ts`, alongside `OverwriteRequiredError`) for the guard.

### 3. UI (`app/ui/archive-panel.ts` + `app/index.html`)

- **Dropdown** (`#target-tag`): add a default first option `<option value="auto" selected>Auto-detect (adapts to the card)</option>`; keep the concrete type options for a preview. `selectedPayloadSize()` returns a nominal default for `auto` (use `CARD_PAYLOAD_SIZE` = 720 as the representative preview size) and the mapped size for concrete types.
- **Estimate counter**: under `auto`, append " (est.) — adapts to the tapped card" to the `≈ N card(s)` text; concrete types read as today.
- **Write flow**: when `writeNextCard` returns `rechunkedTo`, set a status like `Card holds ${payloadSize} B/chunk — writing ${total} card(s) instead of ${originalTotal}.` (`originalTotal` = the count returned by `prepare`). The existing progress `render()` continues from the new total.

### 4. Corrected error message (`app/ui/errors.ts`)

Auto-rechunk removes the common cause; the remaining `CardCapacityError` is a **mid-write** smaller card (card 1 written to an NTAG216, then an NTAG213 tapped). Change the mapping to a true statement:

```
This card is smaller than the ones already written — use cards of the same type, or restart the archive.
```

## Data flow

Archive tab: pick file/text, dropdown (default Auto-detect) sizes the estimate → `prepare(payloadSize=nominal)` → tap first card → `writeNextCard` reads `tag.maxChunkPayload`, re-chunks to it (status note), writes → subsequent cards write against the committed layout. Restore is unchanged (chunks are self-describing).

## Error handling

- Re-chunk only before the first write (`RechunkTooLateError` guards misuse; the flow never calls it after `written>0`).
- A card too small for even one chunk → `createChunks` `RangeError` → panel status "file too large for this card type".
- Mid-write smaller card → `CardCapacityError` with the corrected message; the user can tap a matching card or restart.
- `writeNextCard`'s existing `TagTimeoutError`/`UnsupportedTagError`/`OverwriteRequiredError` handling is unchanged.

## Testing

- **`ArchiveController.rechunkForCapacity`** (`test/controller.test.ts`): prepare at 812, `rechunkForCapacity(73)` → chunk count grows; `assembleChunks(newChunks)` byte-equals `assembleChunks` of the pre-rechunk chunks (payload preserved); `chunks[0].archiveId` unchanged; calling it after a simulated write throws `RechunkTooLateError`.
- **`writeNextCard` auto-rechunk** (`test/controller.test.ts`): `MockTransport` with `maxChunkPayload = 73`; `prepare(payloadSize=812)`; first `writeNextCard` returns `rechunkedTo.total > originalTotal` and writes without throwing; a full archive→small-cards→`RestoreController` restore round-trips byte-identical.
- **Transport `maxChunkPayload`**: `ChameleonBleTransport` reports 720 and `NtagTransport` reports `ntagChunkPayloadSize(type)` — asserted against `FakeChameleon` for one NTAG type (extend the existing `e2e-ntag`/transport tests). `MockTransport` default is 720 and the setter/option works.
- **`estimate`/dropdown**: `selectedPayloadSize()` returns 720 for `auto` and the mapped size for concrete types (small DOM-free assertion if `selectedPayloadSize` is extractable; otherwise covered by the estimate test).

## Out of scope (YAGNI)

- Re-chunking to *fewer* cards purely for optimization when a larger card is tapped is handled for free (first tap always re-chunks to the tapped card's size), but no separate "optimize" UI.
- A confirm dialog before re-chunking (decision: auto + status note).
- Per-card heterogeneous capacities within one archive (the first card commits the layout; mixed-type piles are not supported — matches Flutter).
- Logger integration (deferred until PR #38 merges).

## Global constraints

- Core (`src/`) stays dependency-free, web-platform globals only; no new runtime deps (`dependencies` stays `['chameleon-ultra.js']`).
- ESM NodeNext: intra-project imports use `.js` paths.
- On-tag NFAR byte format is unchanged; re-chunking uses the existing `createChunks`/`assembleChunks` and preserves `archiveId`, flags, and the processed payload bytes exactly.
- Independent of `feat/webapp-log-tab` (PR #38): no import of `src/log/logger.ts`.
- Node ≥ 22 for tests/build; `rm -rf dist` before `npm test`.
