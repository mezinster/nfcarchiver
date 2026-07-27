# Web App Iteration 3 — Metadata Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add filename preservation (Android-compatible), a text-input archive mode with a live card counter, and multi-archive restore (detect all archives on a pile of cards, pick one to restore) to the web app.

**Architecture:** All new logic lives in the app/controller layer over the unchanged core, exactly as Android keeps the filename wrapper in its repository above the core services. A pure `filename.ts` wraps/unwraps the Android metadata format; `estimate.ts` computes card counts; the controllers wrap on archive and detect/unwrap on restore.

**Tech Stack:** TypeScript 5, Node ≥ 22 (via nvm), `node:test`, esbuild. No new runtime deps.

**Spec:** `docs/superpowers/specs/2026-07-28-webapp-metadata-features-design.md`.

## Global Constraints

- Branch: `webapp-metadata-features` (already checked out).
- Every npm/node command runs under Node LTS: prefix `source ~/.nvm/nvm.sh && nvm use --lts` and `rm -rf dist` before `npm test` (stale-dist hazard). `npm test` = `tsc && node --test 'dist/test/**/*.test.js'`.
- Filename wrapper format (verbatim from `lib/features/archive/data/archive_repository.dart:292`): `[2-byte length big-endian][UTF-8 filename bytes, 1..255][original data]`. Applied `wrap → compress → encrypt → chunk`; reversed on restore.
- Core (`crc32`, `chunk`, `chunker`, `crypto`, `gzip`, `pipeline`, `mifare/card-layout`) stays dependency-free and unchanged.
- `CARD_PAYLOAD_SIZE = 720`, `ENCRYPTION_OVERHEAD = 44`. Text mode filename default: `text_note.txt`.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Filename wrapper module

**Files:**
- Create: `webapp/src/filename.ts`
- Test: `webapp/test/filename.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `wrapWithFilename(data: Uint8Array, fileName: string): Uint8Array`
  - `unwrapFilename(data: Uint8Array): { fileName: string | null; data: Uint8Array }`

- [ ] **Step 1: Write the failing test**

`webapp/test/filename.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wrapWithFilename, unwrapFilename } from '../src/filename.js';
import { toHex } from './hex.js';

test('wrap produces [2-byte BE length][utf8 name][data] and round-trips', () => {
  const data = new Uint8Array([10, 20, 30]);
  const wrapped = wrapWithFilename(data, 'a.txt'); // 'a.txt' = 5 bytes
  assert.equal(toHex(wrapped.subarray(0, 2)), '0005');
  assert.deepEqual([...wrapped.subarray(2, 7)], [...new TextEncoder().encode('a.txt')]);
  assert.deepEqual([...wrapped.subarray(7)], [10, 20, 30]);
  const un = unwrapFilename(wrapped);
  assert.equal(un.fileName, 'a.txt');
  assert.deepEqual([...un.data], [10, 20, 30]);
});

test('wrap truncates a filename longer than 255 bytes', () => {
  const wrapped = wrapWithFilename(new Uint8Array([1]), 'x'.repeat(300));
  assert.equal(toHex(wrapped.subarray(0, 2)), '00ff'); // 255
  const un = unwrapFilename(wrapped);
  assert.equal(un.fileName, 'x'.repeat(255));
});

test('a UTF-8 filename round-trips by bytes, not chars', () => {
  const name = 'ключ.txt'; // multi-byte
  const wrapped = wrapWithFilename(new Uint8Array([9]), name);
  const expectedLen = new TextEncoder().encode(name).length;
  assert.equal((wrapped[0]! << 8) | wrapped[1]!, expectedLen);
  assert.equal(unwrapFilename(wrapped).fileName, name);
});

test('unwrap returns null filename + original data for non-wrapped inputs', () => {
  // length < 2
  assert.deepEqual(unwrapFilename(new Uint8Array([7])), { fileName: null, data: new Uint8Array([7]) });
  // declared length 0
  const zero = new Uint8Array([0x00, 0x00, 1, 2]);
  assert.equal(unwrapFilename(zero).fileName, null);
  assert.deepEqual([...unwrapFilename(zero).data], [0, 0, 1, 2]);
  // declared length > available bytes
  const short = new Uint8Array([0x00, 0x40, 1, 2]); // says 64 filename bytes, only 2 present
  assert.equal(unwrapFilename(short).fileName, null);
  // invalid UTF-8 in the filename region
  const badUtf8 = new Uint8Array([0x00, 0x02, 0xff, 0xfe, 9, 9]);
  assert.equal(unwrapFilename(badUtf8).fileName, null);
  assert.deepEqual([...unwrapFilename(badUtf8).data], [0x00, 0x02, 0xff, 0xfe, 9, 9]);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/filename.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/filename.ts`:

```ts
/**
 * Filename metadata wrapper, byte-compatible with the Flutter app
 * (lib/features/archive/data/archive_repository.dart _prependFilenameMetadata /
 *  lib/features/restore/data/restore_repository.dart _extractFilenameMetadata):
 *   [ 2-byte length, big-endian ][ UTF-8 filename (1..255) ][ original data ]
 * Applied to the plaintext before compression/encryption, so the name lives
 * inside the archive and is recoverable from the tags.
 */

const MAX_FILENAME_BYTES = 255;

export function wrapWithFilename(data: Uint8Array, fileName: string): Uint8Array {
  let nameBytes = new TextEncoder().encode(fileName);
  if (nameBytes.length > MAX_FILENAME_BYTES) nameBytes = nameBytes.subarray(0, MAX_FILENAME_BYTES);
  const out = new Uint8Array(2 + nameBytes.length + data.length);
  out[0] = (nameBytes.length >> 8) & 0xff;
  out[1] = nameBytes.length & 0xff;
  out.set(nameBytes, 2);
  out.set(data, 2 + nameBytes.length);
  return out;
}

export function unwrapFilename(data: Uint8Array): { fileName: string | null; data: Uint8Array } {
  if (data.length < 2) return { fileName: null, data };
  const nameLen = (data[0]! << 8) | data[1]!;
  if (nameLen === 0 || nameLen > MAX_FILENAME_BYTES) return { fileName: null, data };
  if (data.length < 2 + nameLen) return { fileName: null, data };
  try {
    const fileName = new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(2, 2 + nameLen));
    return { fileName, data: data.slice(2 + nameLen) };
  } catch {
    return { fileName: null, data };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (75 existing + 4 new = 79 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/filename.ts webapp/test/filename.test.ts
git commit -m "feat(webapp): Android-compatible filename metadata wrapper"
```

---

### Task 2: Card-count estimator

**Files:**
- Create: `webapp/app/estimate.ts`
- Test: `webapp/test/estimate.test.ts`

**Interfaces:**
- Consumes: `wrapWithFilename` (Task 1); `gzipCompress` (`../src/gzip.js`); `ENCRYPTION_OVERHEAD` (`../src/crypto.js`); `CARD_PAYLOAD_SIZE` (`../src/mifare/card-layout.js`).
- Produces: `estimateCardCount(data: Uint8Array, fileName: string, opts: { compress: boolean; encrypted: boolean }): Promise<number>`

- [ ] **Step 1: Write the failing test**

`webapp/test/estimate.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { estimateCardCount } from '../app/estimate.js';

test('empty input is 0 cards', async () => {
  assert.equal(await estimateCardCount(new Uint8Array(0), 'text_note.txt', { compress: false, encrypted: false }), 0);
});

test('uncompressed count uses wrapped size over 720', async () => {
  // fileName 'f' = 1 byte -> wrapped overhead = 2 + 1 = 3.
  const at720 = new Uint8Array(717); // wrapped = 720 -> 1 card
  assert.equal(await estimateCardCount(at720, 'f', { compress: false, encrypted: false }), 1);
  const over = new Uint8Array(718); // wrapped = 721 -> 2 cards
  assert.equal(await estimateCardCount(over, 'f', { compress: false, encrypted: false }), 2);
});

test('encryption adds the 44-byte overhead', async () => {
  const data = new Uint8Array(700); // wrapped (name 'f') = 703; +44 = 747 -> 2 cards
  assert.equal(await estimateCardCount(data, 'f', { compress: false, encrypted: true }), 2);
  assert.equal(await estimateCardCount(data, 'f', { compress: false, encrypted: false }), 1);
});

test('compression shrinks a repetitive payload to a single card', async () => {
  const data = new Uint8Array(4000).fill(0x61); // highly compressible
  assert.equal(await estimateCardCount(data, 'text_note.txt', { compress: false, encrypted: false }), 6);
  assert.equal(await estimateCardCount(data, 'text_note.txt', { compress: true, encrypted: false }), 1);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../app/estimate.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/app/estimate.ts`:

```ts
/**
 * Estimates how many Mifare Classic 1K cards an archive will take, using the
 * same wrap -> compress-if-smaller -> +encryption-overhead pipeline as a real
 * archive so the count matches what will actually be written.
 */

import { wrapWithFilename } from '../src/filename.js';
import { gzipCompress } from '../src/gzip.js';
import { ENCRYPTION_OVERHEAD } from '../src/crypto.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';

export async function estimateCardCount(
  data: Uint8Array,
  fileName: string,
  opts: { compress: boolean; encrypted: boolean },
): Promise<number> {
  if (data.length === 0) return 0;
  const wrapped = wrapWithFilename(data, fileName);
  let processed = wrapped;
  if (opts.compress) {
    const gz = await gzipCompress(wrapped);
    if (gz.length < wrapped.length) processed = gz;
  }
  const size = processed.length + (opts.encrypted ? ENCRYPTION_OVERHEAD : 0);
  return Math.ceil(size / CARD_PAYLOAD_SIZE);
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (79 + 4 = 83 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/app/estimate.ts webapp/test/estimate.test.ts
git commit -m "feat(webapp): live card-count estimator"
```

---

### Task 3: Controllers — filename wrapping + multi-archive restore

**Files:**
- Create: `webapp/src/archive-id.ts`
- Test: `webapp/test/archive-id.test.ts`
- Modify (rewrite): `webapp/app/controller.ts`
- Modify (rewrite): `webapp/test/controller.test.ts`

**Interfaces:**
- Consumes: `wrapWithFilename`/`unwrapFilename` (Task 1); `archive`/`restore` (`../src/pipeline.js`); `decodeChunk`/`encodeChunk`/`FLAG_ENCRYPTED`/`FLAG_COMPRESSED`/`Chunk`/`NfarFormatError` (`../src/chunk.js`); `CARD_PAYLOAD_SIZE`; `Transport`.
- Produces:
  - `formatArchiveId(id: Uint8Array): string` (in `archive-id.ts`)
  - `interface ArchiveRequest { data: Uint8Array; fileName: string; compress: boolean; password?: string }`
  - `ArchiveController.prepare(req): Promise<number>` (now wraps), `writeNextCard(signal?, confirmOverwrite?)` unchanged
  - `interface DetectedArchive { archiveId: string; shortId: string; totalChunks: number; received: number; isEncrypted: boolean; isCompressed: boolean; complete: boolean }`
  - `RestoreController.scanNextCard(signal?): Promise<DetectedArchive[]>`, `detectedArchives(): DetectedArchive[]`, `restore(archiveId: string, password?): Promise<{ data: Uint8Array; fileName: string | null }>`
  - Still exported: `PasswordRequiredError`, `OverwriteRequiredError`, `ArchiveProgress`, `NfarFormatError`. `WrongArchiveError` stays exported but is no longer thrown (removed in Task 4).

- [ ] **Step 1: Write archive-id test + implementation**

`webapp/test/archive-id.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatArchiveId } from '../src/archive-id.js';

test('formats 16 bytes as an 8-4-4-4-12 UUID string', () => {
  const id = Uint8Array.from([
    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
  ]);
  assert.equal(formatArchiveId(id), '01234567-89ab-cdef-1032-547698badcfe');
});
```

`webapp/src/archive-id.ts`:

```ts
/** Formats a 16-byte archive ID as an 8-4-4-4-12 UUID string (matches the Flutter app). */
export function formatArchiveId(id: Uint8Array): string {
  const hex = Array.from(id, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}
```

- [ ] **Step 2: Write the failing controller test (replace the whole file)**

`webapp/test/controller.test.ts` (replace entire file):

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { encodeChunk } from '../src/chunk.js';
import { ArchiveController, RestoreController, PasswordRequiredError, OverwriteRequiredError } from '../app/controller.js';
import { DecryptionError } from '../src/crypto.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
const multiCardData = crypto.getRandomValues(new Uint8Array(2000)); // incompressible -> multiple cards

/** Archive `data` to a source transport and return each card's stored bytes, in order. */
async function archiveToCards(
  data: Uint8Array, opts: { compress: boolean; password?: string; fileName?: string },
): Promise<Uint8Array[]> {
  const src = new MockTransport();
  const ctrl = new ArchiveController(src);
  const total = await ctrl.prepare({ data, fileName: opts.fileName ?? 'blob.bin', compress: opts.compress, password: opts.password });
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i));
    await ctrl.writeNextCard();
    src.enqueueTag(uid(i));
    await src.awaitTag();
    stored.push(await src.readChunk());
  }
  return stored;
}

test('archive writes each card once and reports progress', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false });
  assert.ok(total >= 2, `expected multiple cards, got ${total}`);
  for (let i = 0; i < total; i++) t.enqueueTag(uid(i));
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await ctrl.writeNextCard());
  assert.ok(done);
});

test('archive skips a re-tapped card it already wrote', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false });
  assert.ok(total >= 2);
  t.enqueueTag(uid(0));
  const first = await ctrl.writeNextCard();
  assert.equal(first.progress.written, 1);
  t.enqueueTag(uid(0));
  const repeat = await ctrl.writeNextCard();
  assert.equal(repeat.progress.written, 1);
  assert.equal(repeat.done, false);
});

test('archive requires explicit confirmation to overwrite an NFAR card', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false });
  const existingNfar = encodeChunk({
    archiveId: new Uint8Array(16).fill(1), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  t.enqueueTag(uid(7), existingNfar);
  await assert.rejects(() => ctrl.writeNextCard(undefined, false), OverwriteRequiredError);
  t.enqueueTag(uid(7), existingNfar);
  const ok = await ctrl.writeNextCard(undefined, true);
  assert.equal(ok.progress.written, 1);
});

test('restore recovers the filename and demands a password when encrypted', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, password: 'pw', fileName: 'notes.txt' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((bytes, i) => rt.enqueueTag(uid(i), bytes));

  let detected = await rctrl.scanNextCard();
  let guard = 0;
  while (!detected[0]!.complete && guard++ < 50) detected = await rctrl.scanNextCard();
  assert.equal(detected.length, 1);
  assert.ok(detected[0]!.isEncrypted);
  const id = detected[0]!.archiveId;

  await assert.rejects(() => rctrl.restore(id), PasswordRequiredError);
  await assert.rejects(() => rctrl.restore(id, 'wrong'), DecryptionError);
  const result = await rctrl.restore(id, 'pw');
  assert.equal(result.fileName, 'notes.txt');
  assert.deepEqual(result.data, multiCardData);
});

test('multi-archive detection groups by archive ID and dedups by UID', async () => {
  const a = await archiveToCards(multiCardData, { compress: false, fileName: 'a.bin' });
  const b = await archiveToCards(crypto.getRandomValues(new Uint8Array(900)), { compress: false, fileName: 'b.bin' });

  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  // Interleave the two archives' cards, then re-tap the very first card (dedup).
  a.forEach((bytes, i) => rt.enqueueTag(new Uint8Array([1, 0, 0, i]), bytes));
  b.forEach((bytes, i) => rt.enqueueTag(new Uint8Array([2, 0, 0, i]), bytes));
  rt.enqueueTag(new Uint8Array([1, 0, 0, 0]), a[0]!); // duplicate scan

  let list = await rctrl.scanNextCard();
  for (let i = 0; i < a.length + b.length; i++) list = await rctrl.scanNextCard();
  assert.equal(list.length, 2);
  assert.ok(list.every((d) => d.complete));

  const archiveA = list.find((d) => d.totalChunks === a.length)!;
  const restored = await rctrl.restore(archiveA.archiveId);
  assert.equal(restored.fileName, 'a.bin');
  assert.deepEqual(restored.data, multiCardData);
});

test('restoring an incomplete archive throws', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, fileName: 'x.bin' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  // Enqueue all but the last card.
  for (let i = 0; i < stored.length - 1; i++) rt.enqueueTag(uid(i), stored[i]!);
  let list = await rctrl.scanNextCard();
  for (let i = 1; i < stored.length - 1; i++) list = await rctrl.scanNextCard();
  assert.ok(!list[0]!.complete);
  await assert.rejects(() => rctrl.restore(list[0]!.archiveId));
});

test('writeNextCard/scanNextCard reject with AbortError when the signal is already aborted', async () => {
  const controller = new AbortController();
  controller.abort();

  const t1 = new MockTransport();
  const actrl = new ArchiveController(t1);
  await actrl.prepare({ data: new Uint8Array([1, 2, 3]), fileName: 'x.bin', compress: false });
  await assert.rejects(
    () => actrl.writeNextCard(controller.signal),
    (e: unknown) => e instanceof DOMException && e.name === 'AbortError',
  );

  const t2 = new MockTransport();
  const rctrl = new RestoreController(t2);
  await assert.rejects(
    () => rctrl.scanNextCard(controller.signal),
    (e: unknown) => e instanceof DOMException && e.name === 'AbortError',
  );
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — controller.ts does not yet export `restore(archiveId,...)`/`detectedArchives`, and `prepare` doesn't take `fileName`; type/assertion errors.

- [ ] **Step 4: Rewrite the controller**

`webapp/app/controller.ts` (replace entire file):

```ts
/**
 * DOM-free state machines for the archive and restore flows. They touch only a
 * Transport and are unit-tested against MockTransport. The filename wrapper
 * (matching the Flutter app) is applied here, above the unchanged core.
 */

import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { NfarFormatError } from '../src/chunk.js';
import { wrapWithFilename, unwrapFilename } from '../src/filename.js';
import { formatArchiveId } from '../src/archive-id.js';
import type { Transport } from '../src/transport/transport.js';

export interface ArchiveRequest {
  data: Uint8Array;
  fileName: string;
  compress: boolean;
  password?: string;
}

export interface ArchiveProgress {
  total: number;
  written: number;
  awaiting: number | null;
}

export interface DetectedArchive {
  archiveId: string;
  shortId: string;
  totalChunks: number;
  received: number;
  isEncrypted: boolean;
  isCompressed: boolean;
  complete: boolean;
}

export class OverwriteRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OverwriteRequiredError';
  }
}

export class PasswordRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PasswordRequiredError';
  }
}

/** Retained for compatibility; multi-archive detection no longer throws this. */
export class WrongArchiveError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WrongArchiveError';
  }
}

function uidHex(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

export class ArchiveController {
  private chunks: Chunk[] = [];
  private written = 0;
  private readonly writtenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async prepare(req: ArchiveRequest): Promise<number> {
    const wrapped = wrapWithFilename(req.data, req.fileName);
    this.chunks = await archive(wrapped, {
      payloadSize: CARD_PAYLOAD_SIZE,
      compress: req.compress,
      password: req.password,
    });
    this.written = 0;
    this.writtenUids.clear();
    return this.chunks.length;
  }

  private progress(awaiting: number | null): ArchiveProgress {
    return { total: this.chunks.length, written: this.written, awaiting };
  }

  async writeNextCard(signal?: AbortSignal, confirmOverwrite = false): Promise<{ done: boolean; progress: ArchiveProgress }> {
    if (this.written >= this.chunks.length) return { done: true, progress: this.progress(null) };
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (this.writtenUids.has(key)) {
      return { done: false, progress: this.progress(this.written) };
    }
    if (!confirmOverwrite && (await this.transport.peekIsNfar())) {
      throw new OverwriteRequiredError('This card already holds NFAR data; confirm to overwrite');
    }
    await this.transport.writeChunk(encodeChunk(this.chunks[this.written]!));
    this.writtenUids.add(key);
    this.written += 1;
    const done = this.written >= this.chunks.length;
    return { done, progress: this.progress(done ? null : this.written) };
  }
}

interface ArchiveGroup {
  archiveId: Uint8Array;
  totalChunks: number;
  flags: number;
  chunks: Map<number, Chunk>;
}

export class RestoreController {
  private readonly groups = new Map<string, ArchiveGroup>(); // keyed by formatted UUID
  private readonly seenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async scanNextCard(signal?: AbortSignal): Promise<DetectedArchive[]> {
    const tag = await this.transport.awaitTag({ signal });
    const uid = uidHex(tag.uid);
    if (!this.seenUids.has(uid)) {
      const chunk = decodeChunk(await this.transport.readChunk());
      const id = formatArchiveId(chunk.archiveId);
      let group = this.groups.get(id);
      if (group === undefined) {
        group = { archiveId: chunk.archiveId, totalChunks: chunk.totalChunks, flags: chunk.flags, chunks: new Map() };
        this.groups.set(id, group);
      }
      group.chunks.set(chunk.chunkIndex, chunk);
      this.seenUids.add(uid);
    }
    return this.detectedArchives();
  }

  detectedArchives(): DetectedArchive[] {
    return [...this.groups.entries()].map(([id, g]) => ({
      archiveId: id,
      shortId: id.slice(0, 8),
      totalChunks: g.totalChunks,
      received: g.chunks.size,
      isEncrypted: (g.flags & FLAG_ENCRYPTED) !== 0,
      isCompressed: (g.flags & FLAG_COMPRESSED) !== 0,
      complete: g.chunks.size >= g.totalChunks,
    }));
  }

  async restore(archiveId: string, password?: string): Promise<{ data: Uint8Array; fileName: string | null }> {
    const group = this.groups.get(archiveId);
    if (group === undefined) throw new Error(`No detected archive ${archiveId}`);
    if ((group.flags & FLAG_ENCRYPTED) !== 0 && password === undefined) {
      throw new PasswordRequiredError('This archive is encrypted; a password is required');
    }
    const raw = await restore([...group.chunks.values()], password);
    return unwrapFilename(raw);
  }
}

// Re-export so main.ts and tests can surface a clean not-an-NFAR-card message.
export { NfarFormatError };
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS, 84 total. (The 7 old controller tests are replaced 7-for-7 by the rewritten file, and `archive-id.test.ts` adds 1: 83 → 84.) `restore an incomplete archive` rejects because `pipeline.restore` throws `NfarAssemblyError` on missing chunks — the test enqueues all cards but the last, so the group is genuinely incomplete.

- [ ] **Step 6: Commit**

```bash
git add webapp/src/archive-id.ts webapp/test/archive-id.test.ts webapp/app/controller.ts webapp/test/controller.test.ts
git commit -m "feat(webapp): filename wrapping on archive; multi-archive detection + pick-to-restore"
```

---

### Task 4: UI — text mode, live counter, scan-then-pick restore

**Files:**
- Modify: `webapp/app/index.html`
- Modify: `webapp/app/main.ts`

**Interfaces:**
- Consumes: `ArchiveController`, `RestoreController`, `OverwriteRequiredError`, `PasswordRequiredError`, `NfarFormatError`, `type DetectedArchive` (Task 3); `estimateCardCount` (Task 2); `ChameleonBleTransport`, `SdkChameleonDevice`, transport error types, `CardCapacityError`, `DecryptionError`, diagnostics (existing).
- Produces: no exported API. `main.ts` is DOM glue (untested; verified by tsc + esbuild bundle + manual).

This task removes the now-unused `WrongArchiveError` import/mapping from `main.ts` and deletes the `WrongArchiveError` class from `controller.ts` (nothing throws it after Task 3).

- [ ] **Step 1: Delete the unused WrongArchiveError from the controller**

In `webapp/app/controller.ts`, delete the `WrongArchiveError` class declaration (the `export class WrongArchiveError { … }` block added for compatibility). Confirm nothing else imports it after this task's main.ts edit.

- [ ] **Step 2: Update the HTML (archive textarea + counter; restore scan/list)**

`webapp/app/index.html` — replace the Archive and Restore fieldsets and add a counter style:

Add to `<style>`:

```css
      #cardcount { font-size: 0.9rem; color: #555; margin: 0.3rem 0; }
      #archives .arch { border: 1px solid #ddd; border-radius: 6px; padding: 0.4rem 0.6rem; margin: 0.3rem 0; display: flex; justify-content: space-between; align-items: center; gap: 0.6rem; }
```

Replace the two fieldsets with:

```html
    <fieldset class="row"><legend>Archive a file or text</legend>
      <div class="row"><input type="file" id="file" /></div>
      <div class="row"><label>or text:</label><br /><textarea id="text" rows="3" style="width:100%" placeholder="Type text to archive as text_note.txt"></textarea></div>
      <label><input type="checkbox" id="compress" checked /> compress</label>
      <label>password <input type="password" id="apass" placeholder="(optional)" /></label>
      <div id="cardcount"></div>
      <button id="archive" disabled>Archive to cards</button>
    </fieldset>
    <fieldset class="row"><legend>Restore</legend>
      <button id="scan" disabled>Scan cards</button>
      <button id="stop-scan" disabled>Stop</button>
      <div id="archives"></div>
      <label>save as <input type="text" id="fname" value="restored.bin" /></label>
    </fieldset>
```

(The existing `restore` button is removed; scan-then-pick replaces it.)

- [ ] **Step 3: Rewrite the archive/restore glue in main.ts**

In `webapp/app/main.ts`: remove `WrongArchiveError` from the `./controller.js` import and from `humanError`; add `estimateCardCount` and `type DetectedArchive` imports. Replace the archive click handler and the whole restore handler with the code below, and add the counter wiring + the stop-scan handler. Keep the connect/diagnose handlers and `showProgress`/`hideProgress`/`humanError`/`hex` helpers.

Imports to adjust at the top of main.ts:

```ts
import {
  ArchiveController, RestoreController, OverwriteRequiredError, PasswordRequiredError, NfarFormatError,
  type DetectedArchive,
} from './controller.js';
import { estimateCardCount } from './estimate.js';
```

In `humanError`, delete the `WrongArchiveError` line.

Enable the new buttons on connect: in the connect handler success block, replace the `restore`/`archive` enabling with:

```ts
    ($('archive') as HTMLButtonElement).disabled = false;
    ($('scan') as HTMLButtonElement).disabled = false;
    ($('diagnose') as HTMLButtonElement).disabled = false;
```

Add source tracking + the live counter (place after the helpers, before the connect handler):

```ts
let fileBytes: Uint8Array | null = null;
let fileName = '';

/** Current archive source: the picked file, else the textarea (as text_note.txt). */
function currentSource(): { data: Uint8Array; fileName: string } | null {
  if (fileBytes) return { data: fileBytes, fileName };
  const text = ($('text') as HTMLTextAreaElement).value;
  if (text.length > 0) return { data: new TextEncoder().encode(text), fileName: 'text_note.txt' };
  return null;
}

let counterTimer: ReturnType<typeof setTimeout> | undefined;
function scheduleCounter(): void {
  clearTimeout(counterTimer);
  counterTimer = setTimeout(updateCounter, 200);
}
async function updateCounter(): Promise<void> {
  const src = currentSource();
  const el = $('cardcount');
  if (!src) { el.textContent = ''; return; }
  const compress = ($('compress') as HTMLInputElement).checked;
  const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
  const n = await estimateCardCount(src.data, src.fileName, { compress, encrypted });
  el.textContent = `≈ ${n} card(s)`;
}

$('file').addEventListener('change', async () => {
  const f = ($('file') as HTMLInputElement).files?.[0];
  fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
  fileName = f?.name ?? '';
  updateCounter();
});
for (const id of ['text', 'compress', 'apass']) $(id).addEventListener('input', scheduleCounter);
```

Replace the archive click handler with:

```ts
$('archive').addEventListener('click', async () => {
  if (!transport) return;
  const src = currentSource();
  if (!src) { setStatus('Pick a file or type some text first.'); return; }
  const compress = ($('compress') as HTMLInputElement).checked;
  const pass = ($('apass') as HTMLInputElement).value;
  const ctrl = new ArchiveController(transport);
  const renderArchive = (written: number, total: number, done: boolean) => {
    showProgress(
      done ? `✓ ${written} of ${total} cards written & verified` : `✓ ${written} of ${total} written & verified — tap the next card`,
      written, total,
    );
    setStatus(done ? `Done — wrote and verified ${written} card(s).` : `Tap card ${written + 1} of ${total} on the reader…`);
  };
  try {
    const total = await ctrl.prepare({ data: src.data, fileName: src.fileName, compress, password: pass || undefined });
    renderArchive(0, total, false);
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.writeNextCard();
        done = res.done;
        renderArchive(res.progress.written, total, done);
      } catch (e) {
        if (e instanceof TagTimeoutError) { setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
        if (e instanceof OverwriteRequiredError) {
          if (confirm('This card already holds data. Overwrite it?')) {
            const res = await ctrl.writeNextCard(undefined, true);
            done = res.done;
            renderArchive(res.progress.written, total, done);
          } else { setStatus('Skipped. Tap a different card…'); }
        } else { throw e; }
      }
    }
  } catch (e) {
    hideProgress();
    setStatus(humanError(e));
  }
});
```

Replace the entire restore handler with the scan-then-pick flow:

```ts
let scanAbort: AbortController | null = null;

function renderArchives(list: DetectedArchive[], onPick: (id: string) => void): void {
  const container = $('archives');
  container.innerHTML = '';
  for (const a of list) {
    const row = document.createElement('div');
    row.className = 'arch';
    const label = document.createElement('span');
    label.textContent = `Archive ${a.shortId}…  ${a.isEncrypted ? '🔒 encrypted' : 'unencrypted'}  ·  ${a.received} / ${a.totalChunks} card(s)${a.complete ? ' ✓' : ''}`;
    const btn = document.createElement('button');
    btn.textContent = 'Restore';
    btn.disabled = !a.complete;
    btn.addEventListener('click', () => onPick(a.archiveId));
    row.append(label, btn);
    container.appendChild(row);
  }
}

$('scan').addEventListener('click', async () => {
  if (!transport) return;
  const ctrl = new RestoreController(transport);
  scanAbort = new AbortController();
  let pickedId: string | null = null;
  ($('scan') as HTMLButtonElement).disabled = true;
  ($('stop-scan') as HTMLButtonElement).disabled = false;
  setStatus('Scanning — tap cards on the reader…');
  const onPick = (id: string) => { pickedId = id; scanAbort?.abort(); };

  try {
    for (;;) {
      try {
        const list = await ctrl.scanNextCard(scanAbort.signal);
        renderArchives(list, onPick);
        setStatus(`Detected ${list.length} archive(s). Tap more cards, or Restore a complete one.`);
      } catch (e) {
        if (e instanceof TagTimeoutError) continue;
        if (e instanceof DOMException && e.name === 'AbortError') break;
        throw e;
      }
    }
  } catch (e) {
    setStatus(humanError(e));
  } finally {
    ($('stop-scan') as HTMLButtonElement).disabled = true;
    ($('scan') as HTMLButtonElement).disabled = false;
  }

  if (!pickedId) { setStatus('Stopped scanning.'); return; }

  try {
    let pw: string | undefined;
    let result: { data: Uint8Array; fileName: string | null } | undefined;
    for (let attempt = 0; attempt < 5; attempt++) {
      try { result = await ctrl.restore(pickedId, pw); break; }
      catch (e) {
        if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
          const entered = prompt(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:') ?? undefined;
          if (entered === undefined) { setStatus('Cancelled.'); return; }
          pw = entered; continue;
        }
        throw e;
      }
    }
    if (!result) { setStatus('Too many failed password attempts.'); return; }
    const name = result.fileName ?? (($('fname') as HTMLInputElement).value || 'restored.bin');
    if (result.fileName) ($('fname') as HTMLInputElement).value = result.fileName;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([result.data as BlobPart]));
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
    setStatus(`Restored ${result.data.length} bytes → ${name}.`);
  } catch (e) {
    setStatus(humanError(e));
  }
});

$('stop-scan').addEventListener('click', () => scanAbort?.abort());
```

- [ ] **Step 4: Verify typecheck, tests, and bundle**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-ui-check.js >/dev/null && echo "BUNDLE OK"
```

Expected: all tests PASS (84, unchanged from Task 3 — this is untested glue), `tsc` clean, `BUNDLE OK`. Confirm `grep -rn WrongArchiveError webapp/app webapp/src` returns nothing.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/index.html webapp/app/main.ts webapp/app/controller.ts
git commit -m "feat(webapp): text-input archive mode, live card counter, scan-then-pick restore UI"
```

---

### Task 5: Cross-language filename interop fixtures

**Files:**
- Modify: `tool/generate_web_fixtures.dart`, `webapp/test/interop-dart.test.ts`
- Modify: `webapp/test/write_ts_fixtures.ts`, `tool/verify_web_fixtures.dart`
- Regenerate (committed): `webapp/test/fixtures/dart_generated.json`, `webapp/test/fixtures/ts_generated.json`

**Interfaces:**
- Consumes: production Dart services + the filename wrapper format (Dart side); `decodeChunk`, `restore` (pipeline), `unwrapFilename`, `wrapWithFilename`, `archive` (TS side).
- Produces: new fixture fields proving an Android-format filename-wrapped archive restores on the web with the filename recovered, and vice versa.

- [ ] **Step 1: Add a filename-wrapped archive to the Dart generator**

In `tool/generate_web_fixtures.dart`, add a wrapper helper (byte-identical to `archive_repository.dart:292` `_prependFilenameMetadata`) and a wrapped-archive fixture. Insert before the `json` map:

```dart
Uint8List prependFilename(Uint8List data, String fileName) {
  final nameBytes = utf8.encode(fileName);
  final name = nameBytes.length > 255 ? nameBytes.sublist(0, 255) : nameBytes;
  final out = Uint8List(2 + name.length + data.length);
  out[0] = (name.length >> 8) & 0xFF;
  out[1] = name.length & 0xFF;
  out.setRange(2, 2 + name.length, name);
  out.setRange(2 + name.length, out.length, data);
  return out;
}
```

Then build a wrapped, compressed+encrypted archive (in `main`, before the `json` map):

```dart
  const wrappedFileName = 'my report.txt';
  final wrappedOriginal = Uint8List.fromList(utf8.encode('report body ' * 100));
  final wrapped = prependFilename(wrappedOriginal, wrappedFileName);
  final wrappedCompressed = CompressionService.instance.compress(wrapped);
  final wrappedEncrypted =
      EncryptionService.instance.encrypt(wrappedCompressed, password);
  final wrappedChunks = ChunkerService.instance
      .createChunksWithSize(
        data: wrappedEncrypted,
        payloadSize: 720,
        flags: 0x03, // FLAG_COMPRESSED | FLAG_ENCRYPTED
      )
      .chunks;
```

Add these fields to the `json` map:

```dart
    'wrappedFileName': wrappedFileName,
    'wrappedOriginal': hexOf(wrappedOriginal),
    'wrappedPassword': password,
    'wrappedChunks': wrappedChunks.map((c) => hexOf(c.toBytes())).toList(),
```

- [ ] **Step 2: Generate the Dart fixture**

```bash
cd /home/mezinster/nfcarchiver && dart run tool/generate_web_fixtures.dart
```

Expected: `Wrote webapp/test/fixtures/dart_generated.json` containing the new `wrapped*` fields.

- [ ] **Step 3: Add the web-restores-Dart-wrapped-archive test**

Append to `webapp/test/interop-dart.test.ts` (and add `wrapped*` to its `Fixture` interface):

```ts
import { restore } from '../src/pipeline.js';
import { unwrapFilename } from '../src/filename.js';
// (decodeChunk is already imported in this file)

test('TS restores a Dart filename-wrapped, compressed+encrypted archive and recovers the name', async () => {
  const chunks = fixture.wrappedChunks.map((h) => decodeChunk(fromHex(h)));
  const raw = await restore(chunks, fixture.wrappedPassword);
  const { fileName, data } = unwrapFilename(raw);
  assert.equal(fileName, fixture.wrappedFileName);
  assert.deepEqual(data, fromHex(fixture.wrappedOriginal));
});
```

Add to the `Fixture` interface: `wrappedFileName: string; wrappedOriginal: string; wrappedPassword: string; wrappedChunks: string[];`.

- [ ] **Step 4: Emit a web-wrapped archive for the reverse check**

In `webapp/test/write_ts_fixtures.ts`, add:

```ts
import { wrapWithFilename } from '../src/filename.js';
import { archive } from '../src/pipeline.js';
import { encodeChunk } from '../src/chunk.js';

const wrappedFileName = 'web report.txt';
const wrappedOriginal = new TextEncoder().encode('web body '.repeat(120));
const wrappedChunks = (await archive(wrapWithFilename(wrappedOriginal, wrappedFileName), {
  payloadSize: 720, compress: true, password,
})).map((c) => toHex(encodeChunk(c)));
```

Add to the emitted `fixture` object: `wrappedFileName`, `wrappedOriginal: toHex(wrappedOriginal)`, `wrappedPassword: password`, `wrappedChunks`.

- [ ] **Step 5: Verify the web-wrapped archive from Dart**

In `tool/verify_web_fixtures.dart`, add a filename extractor and a check. Add helper:

```dart
({String fileName, Uint8List data})? extractFilename(Uint8List data) {
  if (data.length < 2) return null;
  final len = (data[0] << 8) | data[1];
  if (len == 0 || len > 255 || data.length < 2 + len) return null;
  try {
    final name = utf8.decode(data.sublist(2, 2 + len));
    return (fileName: name, data: Uint8List.sublistView(data, 2 + len));
  } catch (_) {
    return null;
  }
}
```

Add a check in `main` (alongside the existing ones):

```dart
  final wrappedChunks = (j['wrappedChunks'] as List)
      .map((h) => Chunk.fromBytes(fromHex(h as String)))
      .toList();
  final wrappedAssembled = ChunkerService.instance.assembleChunks(wrappedChunks);
  final wrappedDecrypted = EncryptionService.instance
      .decrypt(wrappedAssembled, j['wrappedPassword'] as String);
  final wrappedPlain = CompressionService.instance.decompress(wrappedDecrypted);
  final extracted = extractFilename(wrappedPlain);
  check(
    extracted != null &&
        extracted.fileName == j['wrappedFileName'] &&
        bytesEqual(extracted.data, fromHex(j['wrappedOriginal'] as String)),
    'filename-wrapped archive from TS (name + data)',
  );
```

- [ ] **Step 6: Generate the TS fixture and run both interop directions**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm run fixtures
cd /home/mezinster/nfcarchiver && dart run tool/verify_web_fixtures.dart
```

Expected: `npm run fixtures` writes `ts_generated.json`; the Dart verifier prints all OK including `filename-wrapped archive from TS (name + data)` and exits 0.

- [ ] **Step 7: Run the full TS suite (regression + Dart→TS interop)**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: all PASS (85 total — the new `TS restores a Dart filename-wrapped …` test brings 84 → 85).

- [ ] **Step 8: Commit**

```bash
git add tool/generate_web_fixtures.dart tool/verify_web_fixtures.dart webapp/test/interop-dart.test.ts webapp/test/write_ts_fixtures.ts webapp/test/fixtures/dart_generated.json webapp/test/fixtures/ts_generated.json
git commit -m "test(webapp): cross-language filename-wrapper interop (phone<->browser)"
```

---

## Completion Criteria

- `npm test` in `webapp/` passes on Node LTS (with `rm -rf dist` first).
- `npx tsc --noEmit` clean; `npx esbuild app/main.ts --bundle` succeeds.
- `dart run tool/verify_web_fixtures.dart` prints all OK (incl. the filename-wrapper check) and exits 0.
- Core modules unchanged; no new runtime dependencies.
- `WrongArchiveError` fully removed; no references remain.
