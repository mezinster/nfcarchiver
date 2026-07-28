# Web App Dynamic Chip-Capacity Re-chunking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make archiving adapt to the tapped chip's real capacity — on the first tap, auto-re-chunk to fit — so a card smaller than the selected tag type no longer fails with `CardCapacityError`.

**Architecture:** The transport already knows each card's real per-card NFAR chunk-payload; expose it on `PresentedTag.maxChunkPayload`. `ArchiveController` gains `rechunkForCapacity(newPayloadSize)` that re-splits the already-processed payload (preserving `archiveId`, no re-encrypt), and `writeNextCard` auto-calls it on the first tap. The target-tag dropdown becomes an estimate hint with an Auto-detect default; the misleading capacity error is corrected.

**Tech Stack:** TypeScript (ESM NodeNext — imports use `.js`), esbuild, `node --test`.

## Global Constraints

- Core (`src/`) stays dependency-free, web-platform globals only; no new runtime deps (`dependencies` stays exactly `{ "chameleon-ultra.js" }`).
- ESM NodeNext: every intra-project import uses the compiled `.js` path.
- On-tag NFAR byte format is unchanged; re-chunking uses `createChunks`/`assembleChunks` and preserves `archiveId`, flags, and the processed payload bytes exactly.
- Re-chunk is valid ONLY before the first card is written (each chunk header carries `totalChunks`+index).
- Independent of `feat/webapp-log-tab` (PR #38): do NOT import `src/log/logger.ts`. Surface the re-chunk via the archive status line.
- Node ≥ 22 for tests/build: `source ~/.nvm/nvm.sh && nvm use --lts` first (shell default is Node 14). `rm -rf dist` before running tests: `rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'`.

---

## File Structure

- `src/transport/transport.ts` (modify) — add `maxChunkPayload` to `PresentedTag`.
- `src/transport/chameleon-ble.ts` (modify) — return `maxChunkPayload: CARD_PAYLOAD_SIZE`.
- `src/transport/ntag-transport.ts` (modify) — return `maxChunkPayload: ntagChunkPayloadSize(type)`.
- `src/transport/mock-transport.ts` (modify) — settable `maxChunkPayload` (default `CARD_PAYLOAD_SIZE`).
- `app/controller.ts` (modify) — `RechunkTooLateError`, `ArchiveController.rechunkForCapacity`, `writeNextCard` auto-rechunk + `rechunkedTo`.
- `app/ui/archive-panel.ts` (modify) — Auto-detect payload size, estimate note, re-chunk status.
- `app/index.html` (modify) — Auto-detect dropdown option.
- `app/ui/errors.ts` (modify) — corrected `CardCapacityError` message.
- Tests: `test/chameleon-ble.test.ts`, `test/ntag-transport.test.ts`, `test/controller.test.ts`, `test/errors.test.ts` (all extend existing files).

---

## Task 1: `PresentedTag.maxChunkPayload` on all transports

**Files:**
- Modify: `webapp/src/transport/transport.ts`, `webapp/src/transport/chameleon-ble.ts`, `webapp/src/transport/ntag-transport.ts`, `webapp/src/transport/mock-transport.ts`
- Test: `webapp/test/chameleon-ble.test.ts`, `webapp/test/ntag-transport.test.ts` (extend)

**Interfaces:**
- Consumes: `CARD_PAYLOAD_SIZE` (`src/mifare/card-layout.ts`, value 720), `ntagChunkPayloadSize`/`ntagUserBytes` (`src/nfc/type2.ts`).
- Produces: `PresentedTag.maxChunkPayload: number` on every `awaitTag`; `MockTransport.maxChunkPayload` public settable field.

- [ ] **Step 1: Write the failing test**

In `webapp/test/chameleon-ble.test.ts`, add `CARD_PAYLOAD_SIZE` to the card-layout import (it already imports `USABLE_BLOCK_INDEXES` from `'../src/mifare/card-layout.js'`):
```ts
import { USABLE_BLOCK_INDEXES, CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
```
In the existing test `'connect delegates to the device; awaitTag polls scanTag'`, after the line `const tag = await transport.awaitTag();`, add:
```ts
  assert.equal(tag.maxChunkPayload, CARD_PAYLOAD_SIZE);
```

In `webapp/test/ntag-transport.test.ts`, in the existing test that does `device.placeNtag(uid, NtagType.NTAG215); const tag = await t.awaitTag();` and asserts `tag.capacityBytes === 504`, add right after that assertion:
```ts
  assert.equal(tag.maxChunkPayload, ntagChunkPayloadSize(NtagType.NTAG215));
```
(`ntagChunkPayloadSize` and `NtagType` are already imported there.)

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Property 'maxChunkPayload' does not exist on type 'PresentedTag'`.

- [ ] **Step 3: Add the field to the interface and every implementation**

In `webapp/src/transport/transport.ts`, change `PresentedTag`:
```ts
export interface PresentedTag {
  uid: Uint8Array;
  capacityBytes: number;   // raw user memory (informational)
  maxChunkPayload: number; // max NFAR chunk-payload this card holds
}
```

In `webapp/src/transport/chameleon-ble.ts`: add `CARD_PAYLOAD_SIZE` to the existing `../mifare/card-layout.js` import, and change the `awaitTag` return:
```ts
if (tag !== null) return { uid: tag.uid, capacityBytes: CARD_CAPACITY_BYTES, maxChunkPayload: CARD_PAYLOAD_SIZE };
```

In `webapp/src/transport/ntag-transport.ts`, change the `awaitTag` return (both `ntagUserBytes` and `ntagChunkPayloadSize` are already imported):
```ts
const type = await this.detectType();
return { uid: tag.uid, capacityBytes: ntagUserBytes(type), maxChunkPayload: ntagChunkPayloadSize(type) };
```

In `webapp/src/transport/mock-transport.ts`: add `CARD_PAYLOAD_SIZE` to the existing `../mifare/card-layout.js` import, add a public field, and return it. Add the field near the top of the class:
```ts
  /** Simulated per-card NFAR chunk-payload capacity; tests set this to model a small chip. */
  maxChunkPayload = CARD_PAYLOAD_SIZE;
```
and change the `awaitTag` success return to:
```ts
    this.active = next;
    return { uid: Uint8Array.from(next.match(/../g)!.map((h) => parseInt(h, 16))), capacityBytes: CARD_CAPACITY_BYTES, maxChunkPayload: this.maxChunkPayload };
```

`AutoTransport.awaitTag` returns the delegate's `PresentedTag` unchanged, so it needs no edit.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
```
Expected: PASS — the two new assertions plus all pre-existing tests (tsc now clean; every `awaitTag` return site provides `maxChunkPayload`).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/transport/transport.ts webapp/src/transport/chameleon-ble.ts webapp/src/transport/ntag-transport.ts webapp/src/transport/mock-transport.ts webapp/test/chameleon-ble.test.ts webapp/test/ntag-transport.test.ts
git commit -m "feat(webapp): PresentedTag.maxChunkPayload exposes each card's real per-card capacity"
```

---

## Task 2: `ArchiveController` auto-rechunk

**Files:**
- Modify: `webapp/app/controller.ts`
- Test: `webapp/test/controller.test.ts` (extend)

**Interfaces:**
- Consumes: `PresentedTag.maxChunkPayload` + `MockTransport.maxChunkPayload` (Task 1); `assembleChunks` (already imported in `controller.ts`), `createChunks` (`src/chunker.ts`).
- Produces:
  - `class RechunkTooLateError extends Error`
  - `ArchiveController.rechunkForCapacity(newPayloadSize: number): number`
  - `ArchiveController.writeNextCard(...)` return type gains `rechunkedTo?: { total: number; payloadSize: number }`.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/controller.test.ts` (it already imports `MockTransport`, `ArchiveController`, `RestoreController`, `decodeChunk`, and has `uid`, `multiCardData`; add `RechunkTooLateError` to the `../app/controller.js` import and `decodeChunk` is already imported from `../src/chunk.js`):

```ts
test('rechunkForCapacity grows the chunk count for a smaller card and refuses after a write', async () => {
  const t = new MockTransport();
  t.maxChunkPayload = 73; // simulate an NTAG213-sized card so writeNextCard won't re-rechunk
  const ctrl = new ArchiveController(t);
  const big = await ctrl.prepare({ data: multiCardData, fileName: 'x.bin', compress: false, payloadSize: 720 });
  const small = ctrl.rechunkForCapacity(73);
  assert.ok(small > big, `expected more chunks after shrinking: ${small} > ${big}`);
  t.enqueueTag(uid(0));
  await ctrl.writeNextCard(); // 73 === current payloadSize -> no auto-rechunk; writes card 0
  assert.throws(() => ctrl.rechunkForCapacity(428), RechunkTooLateError);
});

test('writeNextCard auto-rechunks to the tapped card and still restores byte-identically', async () => {
  const t = new MockTransport();
  t.maxChunkPayload = 73; // the tapped card is much smaller than the selected NTAG216
  const ctrl = new ArchiveController(t);
  const originalTotal = await ctrl.prepare({ data: multiCardData, fileName: 'x.bin', compress: false, payloadSize: 812 });

  const stored: Uint8Array[] = [];
  let done = false, i = 0, guard = 0;
  let firstRechunk: { total: number; payloadSize: number } | undefined;
  while (!done && guard++ < 1000) {
    t.enqueueTag(uid(i));
    const res = await ctrl.writeNextCard();
    if (res.rechunkedTo && firstRechunk === undefined) firstRechunk = res.rechunkedTo;
    done = res.done;
    t.enqueueTag(uid(i)); await t.awaitTag(); stored.push(await t.readChunk()); // read back this card
    i++;
  }
  assert.ok(firstRechunk, 'the first tap reported a re-chunk');
  assert.equal(firstRechunk!.payloadSize, 73);
  assert.ok(firstRechunk!.total > originalTotal, `more, smaller cards: ${firstRechunk!.total} > ${originalTotal}`);
  assert.equal(stored.length, firstRechunk!.total);
  // all written cards share one archiveId (coherent archive)
  const ids = new Set(stored.map((b) => decodeChunk(b).archiveId.join(',')));
  assert.equal(ids.size, 1);

  // restore the small-card pile -> byte-identical to the original data
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((b, j) => rt.enqueueTag(uid(j), b));
  let list = await rctrl.scanNextCard();
  for (let j = 1; j < stored.length; j++) list = await rctrl.scanNextCard();
  assert.ok(list[0]!.complete);
  const result = await rctrl.restore(list[0]!.archiveId);
  assert.deepEqual(result.data, multiCardData);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `RechunkTooLateError` and `rechunkForCapacity` / `rechunkedTo` do not exist.

- [ ] **Step 3: Implement**

In `webapp/app/controller.ts`:

1. Add `createChunks` to the chunker import (the file already imports `assembleChunks` from `'../src/chunker.js'`):
```ts
import { assembleChunks, createChunks } from '../src/chunker.js';
```

2. Add the error class next to `OverwriteRequiredError`:
```ts
export class RechunkTooLateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RechunkTooLateError';
  }
}
```

3. In `class ArchiveController`, add a `payloadSize` field, set it in `prepare`, add `rechunkForCapacity`, and auto-rechunk in `writeNextCard`. Replace the class body's fields + `prepare` + `writeNextCard` with:
```ts
  private chunks: Chunk[] = [];
  private written = 0;
  private payloadSize = 0;
  private readonly writtenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async prepare(req: ArchiveRequest): Promise<number> {
    const wrapped = wrapWithFilename(req.data, req.fileName);
    this.chunks = await archive(wrapped, {
      payloadSize: req.payloadSize,
      compress: req.compress,
      password: req.password,
    });
    this.payloadSize = req.payloadSize;
    this.written = 0;
    this.writtenUids.clear();
    return this.chunks.length;
  }

  /** Re-split the already-processed payload to a new per-card size, preserving the
   *  archiveId (no re-encrypt). Only valid before any card is written. */
  rechunkForCapacity(newPayloadSize: number): number {
    if (this.written > 0) throw new RechunkTooLateError('Cannot re-chunk after writing has started');
    const payload = assembleChunks(this.chunks);
    const { flags, archiveId } = this.chunks[0]!;
    this.chunks = createChunks(payload, newPayloadSize, flags, archiveId);
    this.payloadSize = newPayloadSize;
    return this.chunks.length;
  }

  private progress(awaiting: number | null): ArchiveProgress {
    return { total: this.chunks.length, written: this.written, awaiting };
  }

  async writeNextCard(signal?: AbortSignal, confirmOverwrite = false): Promise<{ done: boolean; progress: ArchiveProgress; rechunkedTo?: { total: number; payloadSize: number } }> {
    if (this.written >= this.chunks.length) return { done: true, progress: this.progress(null) };
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (this.writtenUids.has(key)) {
      return { done: false, progress: this.progress(this.written) };
    }
    let rechunkedTo: { total: number; payloadSize: number } | undefined;
    if (this.written === 0 && tag.maxChunkPayload !== this.payloadSize) {
      const total = this.rechunkForCapacity(tag.maxChunkPayload);
      rechunkedTo = { total, payloadSize: tag.maxChunkPayload };
    }
    if (!confirmOverwrite && (await this.transport.peekIsNfar())) {
      throw new OverwriteRequiredError('This card already holds NFAR data; confirm to overwrite');
    }
    await this.transport.writeChunk(encodeChunk(this.chunks[this.written]!));
    this.writtenUids.add(key);
    this.written += 1;
    const done = this.written >= this.chunks.length;
    return { done, progress: this.progress(done ? null : this.written), ...(rechunkedTo ? { rechunkedTo } : {}) };
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/controller.test.js
```
Expected: PASS — the two new tests plus all pre-existing controller tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/controller.ts webapp/test/controller.test.ts
git commit -m "feat(webapp): ArchiveController auto-rechunks to the tapped card's capacity"
```

---

## Task 3: UI (Auto-detect dropdown, estimate note, re-chunk status) + corrected error

**Files:**
- Modify: `webapp/app/index.html`, `webapp/app/ui/archive-panel.ts`, `webapp/app/ui/errors.ts`
- Test: `webapp/test/errors.test.ts` (update the CardCapacityError assertion)

**Interfaces:**
- Consumes: `writeNextCard`'s `rechunkedTo` (Task 2); `CARD_PAYLOAD_SIZE` (`src/mifare/card-layout.ts`).
- Produces: no new exported interface.

- [ ] **Step 1: Update the error-message test (failing)**

`webapp/test/errors.test.ts` currently asserts the message with a regex: `assert.match(humanError(new CardCapacityError('x')), /too large/i);`. Change that regex to match the corrected message:
```ts
  assert.match(humanError(new CardCapacityError('x')), /smaller than the ones already written/i);
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/errors.test.js
```
Expected: FAIL — the corrected regex does not match the old "too large" message yet.

- [ ] **Step 3: Correct the message**

In `webapp/app/ui/errors.ts`, change the `CardCapacityError` branch:
```ts
  if (e instanceof CardCapacityError) return 'This card is smaller than the ones already written — use cards of the same type, or restart the archive.';
```

- [ ] **Step 4: Add the Auto-detect dropdown option**

In `webapp/app/index.html`, in the `<select id="target-tag">`, add a new first option and remove any `selected` on the others (there is none today; `auto` becomes the default by being first + `selected`):
```html
            <select id="target-tag">
              <option value="auto" selected>Auto-detect (adapts to the card)</option>
              <option value="720">Mifare Classic 1K — 752 B</option>
              <option value="NTAG213">NTAG213 — 144 B</option>
              <option value="NTAG215">NTAG215 — 504 B</option>
              <option value="NTAG216">NTAG216 — 888 B</option>
            </select>
```

- [ ] **Step 5: Wire Auto-detect + estimate note + re-chunk status in archive-panel**

In `webapp/app/ui/archive-panel.ts`:

1. Add the `CARD_PAYLOAD_SIZE` import (near the other `../../src/...` imports):
```ts
import { CARD_PAYLOAD_SIZE } from '../../src/mifare/card-layout.js';
```

2. In `selectedPayloadSize()`, handle `'auto'` (add as the first check):
```ts
function selectedPayloadSize(): number {
  const v = ($('target-tag') as HTMLSelectElement).value;
  if (v === 'auto') return CARD_PAYLOAD_SIZE; // nominal preview size; the real card decides on tap
  if (v === 'NTAG213') return ntagChunkPayloadSize(NtagType.NTAG213);
  if (v === 'NTAG215') return ntagChunkPayloadSize(NtagType.NTAG215);
  if (v === 'NTAG216') return ntagChunkPayloadSize(NtagType.NTAG216);
  return Number(v); // "720" for Mifare Classic 1K
}
```

3. In `updateCounter`, append the estimate note under Auto-detect. Replace the counter-text line:
```ts
    const count = await estimateCardCount(src.data, src.fileName, { compress, encrypted, payloadSize: selectedPayloadSize() });
    const isAuto = ($('target-tag') as HTMLSelectElement).value === 'auto';
    el.textContent = `≈ ${count} card(s)${isAuto ? ' (est.) — adapts to the tapped card' : ''}`;
```

4. In the `$('archive').click` handler, make `total` reassignable and show the re-chunk note. Change `const total = await ctrl.prepare(...)` to `let total = await ctrl.prepare(...)`, and inside the `while (!done)` loop, right after `const res = await ctrl.writeNextCard();`, add:
```ts
          if (res.rechunkedTo) {
            const orig = total;
            total = res.rechunkedTo.total;
            setStatus(`Card holds ${res.rechunkedTo.payloadSize} B/chunk — writing ${total} card(s) instead of ${orig}.`);
          }
```
(Leave the existing `done = res.done; render(res.progress.written, total, done);` lines after it — `render` now uses the updated `total`. The overwrite-confirm branch's `ctrl.writeNextCard(undefined, true)` needs no change: any re-chunk already happened on the first, throwing call.)

- [ ] **Step 6: Type-check, run the full suite, build the bundle**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/capacity-bundle-check.js
```
Expected: `tsc` clean; all tests pass (the updated errors test + everything else); esbuild prints a size with no errors. (The archive-panel wiring is UI glue; its logic — `rechunkForCapacity`/`writeNextCard` — is covered by Task 2, and the corrected message by the errors test.)

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/archive-panel.ts webapp/app/ui/errors.ts webapp/test/errors.test.ts
git commit -m "feat(webapp): Auto-detect target tag, re-chunk status note, corrected capacity error"
```

---

## Final verification (after all tasks)

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'   # all pass
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/capacity-bundle-check.js  # builds
node -e "console.log(Object.keys(require('./package.json').dependencies))"        # ['chameleon-ultra.js']
grep -rn "log/logger" app/ui/archive-panel.ts app/controller.ts src/transport || echo "no logger dependency (independent of PR #38)"
```

**Manual browser smoke (Windows-host Chromium + Chameleon):** on the Archive tab with **Auto-detect** selected, choose a file that needs several cards; tap a card smaller than the estimate assumed → confirm the status shows "writing N cards instead of M" and the write proceeds and verifies; restore the pile and confirm the file is byte-identical. Also try selecting a concrete large type (NTAG216) then tapping a smaller card → same adaptive behavior.

Then use **superpowers:finishing-a-development-branch** to open the PR (base `master`).
