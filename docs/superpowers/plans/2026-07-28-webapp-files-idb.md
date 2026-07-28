# Web App Files Tab (IndexedDB Archive Store) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the web app's placeholder Files tab into a working, IndexedDB-backed history of restored archives — each entry re-downloadable, encrypted archives stored as ciphertext and re-decrypted with the password on download.

**Architecture:** A dependency-free `FileStore` seam (`InMemoryFileStore` for tests, `IdbFileStore` for the browser) holds `StoredFile` records. A DOM-free `FilesController` orchestrates save/list/delete/clear/download over the store; a `files-view` reconcile renderer and `files-panel` glue drive the UI. Restore capture happens in `restore-panel` on a successful restore, storing the assembled chunk payload (ciphertext when encrypted) plus cleartext metadata.

**Tech Stack:** TypeScript (ESM, `node16` module resolution — imports use `.js`), esbuild, `node --test`, web-platform `indexedDB`/`crypto.subtle`/`CompressionStream`. No new runtime dependencies.

## Global Constraints

- Core (`src/`) stays dependency-free and uses only web-platform globals. `indexedDB` is referenced ONLY in `src/storage/idb-file-store.ts` (storage fence, analogous to the `chameleon-ultra.js` SDK fence).
- No new runtime dependencies; `package.json` `dependencies` stays `{ "chameleon-ultra.js" }`.
- On-tag byte formats and the NFAR pipeline are unchanged; this feature only reads assembled payloads and stores them locally.
- Node ≥ 22 for tests/build: `source ~/.nvm/nvm.sh && nvm use --lts` first (shell default is Node 14).
- `rm -rf dist` before running tests (stale compiled tests otherwise linger): full run is `rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'`.
- Reuse existing errors (`PasswordRequiredError` from `app/controller.ts`, `DecryptionError` from `src/crypto.ts`).
- Use the in-place reconcile render pattern (`app/ui/restore-view.ts`); never reintroduce `innerHTML = ''` list rebuilds.
- Capture is **restore-only**. Encrypted archives store ciphertext at rest; metadata (name/size/date/flags/card count) is cleartext.
- All ESM imports within the project reference the compiled `.js` path (e.g. `import { X } from './file-store.js'`), even from `.ts` sources — this repo compiles with that convention.

---

## File Structure

- `src/storage/file-store.ts` (create) — `StoredFile`, `FileListItem`, `StorageInfo`, `FileStore` interface, `InMemoryFileStore`.
- `src/storage/idb-file-store.ts` (create) — `IdbFileStore implements FileStore` over `indexedDB`. Only file touching IndexedDB.
- `src/pipeline.ts` (modify) — add `restoreFromPayload()`, refactor `restore()` to use it.
- `app/controller.ts` (modify) — add `RestoreController.assembledPayload(archiveId)`.
- `app/files-controller.ts` (create) — DOM-free orchestration over a `FileStore`.
- `app/ui/files-view.ts` (create) — in-place reconcile renderer + `humanSize`.
- `app/ui/files-panel.ts` (create) — DOM glue (list/download/delete/clear/refresh-on-tab).
- `app/ui/restore-panel.ts` (modify) — save a Files entry after a successful restore.
- `app/index.html` (modify) — replace the Files placeholder with the panel markup.
- `app/main.ts` (modify) — wire `initFilesPanel()`.
- Tests: `test/file-store.test.ts`, `test/pipeline.test.ts` (may already exist — extend), `test/controller.test.ts` (extend), `test/files-controller.test.ts`, `test/files-view.test.ts`.

---

## Task 1: FileStore core + InMemoryFileStore

**Files:**
- Create: `webapp/src/storage/file-store.ts`
- Test: `webapp/test/file-store.test.ts`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `interface StoredFile { id: string; name: string; size: number; createdAt: number; isEncrypted: boolean; isCompressed: boolean; totalChunks: number; payload: Uint8Array; }`
  - `type FileListItem = Omit<StoredFile, 'payload'>`
  - `interface StorageInfo { count: number; totalBytes: number; }`
  - `interface FileStore { list(): Promise<StoredFile[]>; save(f: StoredFile): Promise<void>; get(id: string): Promise<StoredFile | null>; delete(id: string): Promise<void>; clear(): Promise<number>; info(): Promise<StorageInfo>; }`
  - `class InMemoryFileStore implements FileStore`

- [ ] **Step 1: Write the failing test**

Create `webapp/test/file-store.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryFileStore, type StoredFile } from '../src/storage/file-store.js';

const mk = (over: Partial<StoredFile>): StoredFile => ({
  id: 'id-1', name: 'a.bin', size: 3, createdAt: 1000,
  isEncrypted: false, isCompressed: false, totalChunks: 1,
  payload: new Uint8Array([1, 2, 3]), ...over,
});

test('save + get round-trips a record', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({}));
  const got = await s.get('id-1');
  assert.equal(got?.name, 'a.bin');
  assert.deepEqual([...(got!.payload)], [1, 2, 3]);
});

test('get returns null for a missing id', async () => {
  const s = new InMemoryFileStore();
  assert.equal(await s.get('nope'), null);
});

test('list returns records newest-first by createdAt', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'old', createdAt: 100 }));
  await s.save(mk({ id: 'new', createdAt: 200 }));
  const ids = (await s.list()).map((f) => f.id);
  assert.deepEqual(ids, ['new', 'old']);
});

test('save upserts by id (no duplicates)', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'x', name: 'first' }));
  await s.save(mk({ id: 'x', name: 'second' }));
  const list = await s.list();
  assert.equal(list.length, 1);
  assert.equal(list[0]!.name, 'second');
});

test('delete removes one record', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'x' }));
  await s.delete('x');
  assert.equal(await s.get('x'), null);
});

test('clear empties the store and returns the count removed', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'a' }));
  await s.save(mk({ id: 'b' }));
  assert.equal(await s.clear(), 2);
  assert.equal((await s.list()).length, 0);
});

test('info reports count and summed payload bytes', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'a', payload: new Uint8Array(10) }));
  await s.save(mk({ id: 'b', payload: new Uint8Array(15) }));
  assert.deepEqual(await s.info(), { count: 2, totalBytes: 25 });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Cannot find module '../src/storage/file-store.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/src/storage/file-store.ts`:

```ts
/**
 * Local store of restored archives. `InMemoryFileStore` backs the record with a
 * Map and is the store used by all unit tests; `IdbFileStore` (browser) provides
 * the persistent implementation of the same contract.
 */

export interface StoredFile {
  id: string;            // archive UUID string; primary key (upsert de-dupes re-restores)
  name: string;          // recovered filename (cleartext metadata)
  size: number;          // plaintext byte length, for display
  createdAt: number;     // epoch ms when saved
  isEncrypted: boolean;
  isCompressed: boolean;
  totalChunks: number;   // card count
  payload: Uint8Array;   // assembled chunk payload: ciphertext if encrypted, else wrapped(+gzip) plaintext
}

export type FileListItem = Omit<StoredFile, 'payload'>;

export interface StorageInfo {
  count: number;
  totalBytes: number;
}

export interface FileStore {
  list(): Promise<StoredFile[]>;         // newest-first (createdAt desc)
  save(file: StoredFile): Promise<void>; // upsert by id
  get(id: string): Promise<StoredFile | null>;
  delete(id: string): Promise<void>;
  clear(): Promise<number>;              // returns number of records removed
  info(): Promise<StorageInfo>;
}

export class InMemoryFileStore implements FileStore {
  private readonly records = new Map<string, StoredFile>();

  async list(): Promise<StoredFile[]> {
    return [...this.records.values()].sort((a, b) => b.createdAt - a.createdAt);
  }
  async save(file: StoredFile): Promise<void> {
    this.records.set(file.id, file);
  }
  async get(id: string): Promise<StoredFile | null> {
    return this.records.get(id) ?? null;
  }
  async delete(id: string): Promise<void> {
    this.records.delete(id);
  }
  async clear(): Promise<number> {
    const n = this.records.size;
    this.records.clear();
    return n;
  }
  async info(): Promise<StorageInfo> {
    let totalBytes = 0;
    for (const r of this.records.values()) totalBytes += r.payload.length;
    return { count: this.records.size, totalBytes };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/file-store.test.js
```
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/storage/file-store.ts webapp/test/file-store.test.ts
git commit -m "feat(webapp): FileStore seam + InMemoryFileStore for the Files tab"
```

---

## Task 2: `restoreFromPayload` helper + refactor `pipeline.restore`

**Files:**
- Modify: `webapp/src/pipeline.ts`
- Test: `webapp/test/pipeline.test.ts` (append — the file already exists)

**Interfaces:**
- Consumes: `assembleChunks` (`src/chunker.ts`), `decrypt`/`DecryptionError` (`src/crypto.ts`), `gzipDecompress` (`src/gzip.ts`), `FLAG_COMPRESSED`/`FLAG_ENCRYPTED` (`src/chunk.ts`).
- Produces: `restoreFromPayload(payload: Uint8Array, opts: { isEncrypted: boolean; isCompressed: boolean }, password?: string): Promise<Uint8Array>` — returns the still-filename-wrapped bytes (decrypt → decompress; NO unwrap). `restore()` keeps its existing signature `restore(chunks: Chunk[], password?): Promise<Uint8Array>`.

- [ ] **Step 1: Write the failing test**

`webapp/test/pipeline.test.ts` already exists and imports `{ archive, restore }` from `../src/pipeline.js`, `{ FLAG_COMPRESSED, FLAG_ENCRYPTED }` from `../src/chunk.js`, `{ DecryptionError }` from `../src/crypto.js`, and declares a `const random = crypto.getRandomValues(new Uint8Array(300));`. Make two edits:

1. Add `restoreFromPayload` to the pipeline import and add a chunker import:
```ts
import { archive, restore, restoreFromPayload } from '../src/pipeline.js';
import { assembleChunks } from '../src/chunker.js';
```
2. Append these tests to the end of the file (reusing the existing `random` fixture — do NOT declare a new one):
```ts
test('restoreFromPayload reverses archive for a plain payload', async () => {
  const chunks = await archive(random, { payloadSize: 720 });
  const payload = assembleChunks(chunks);
  const out = await restoreFromPayload(payload, { isEncrypted: false, isCompressed: false });
  assert.deepEqual(out, random);
});

test('restoreFromPayload decrypts + decompresses an encrypted+compressed payload', async () => {
  const chunks = await archive(random, { payloadSize: 720, compress: true, password: 'pw' });
  const flags = chunks[0]!.flags;
  const payload = assembleChunks(chunks);
  const out = await restoreFromPayload(
    payload,
    { isEncrypted: (flags & FLAG_ENCRYPTED) !== 0, isCompressed: (flags & FLAG_COMPRESSED) !== 0 },
    'pw',
  );
  assert.deepEqual(out, random);
});

test('restoreFromPayload throws DecryptionError on wrong password', async () => {
  const chunks = await archive(random, { payloadSize: 720, password: 'pw' });
  const payload = assembleChunks(chunks);
  await assert.rejects(
    () => restoreFromPayload(payload, { isEncrypted: true, isCompressed: false }, 'nope'),
    DecryptionError,
  );
});

test('restore still round-trips via the shared helper', async () => {
  const chunks = await archive(random, { payloadSize: 720, compress: true, password: 'pw' });
  assert.deepEqual(await restore(chunks, 'pw'), random);
});
```
Note: `random` is incompressible, so in the encrypted+compressed test the `FLAG_COMPRESSED` bit may be absent (archive only sets it if gzip actually shrinks). The test reads the real `flags` off the chunk rather than assuming, so it passes either way.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `restoreFromPayload` is not exported by `../src/pipeline.js`.

- [ ] **Step 3: Write minimal implementation**

In `webapp/src/pipeline.ts`, replace the `restore` function with the helper + a thin `restore`:

```ts
export async function restoreFromPayload(
  payload: Uint8Array,
  opts: { isEncrypted: boolean; isCompressed: boolean },
  password?: string,
): Promise<Uint8Array> {
  let data = payload;
  if (opts.isEncrypted) {
    if (password === undefined) {
      throw new DecryptionError('Archive is encrypted; password required');
    }
    data = await decrypt(data, password);
  }
  if (opts.isCompressed) {
    data = await gzipDecompress(data);
  }
  return data;
}

export async function restore(chunks: Chunk[], password?: string): Promise<Uint8Array> {
  const flags = chunks[0]!.flags;
  return restoreFromPayload(
    assembleChunks(chunks),
    { isEncrypted: (flags & FLAG_ENCRYPTED) !== 0, isCompressed: (flags & FLAG_COMPRESSED) !== 0 },
    password,
  );
}
```

Leave the existing imports (`assembleChunks`, `decrypt`, `DecryptionError`, `gzipDecompress`, `FLAG_*`, `Chunk`) in place — they are all still used.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
```
Expected: PASS — new pipeline tests green AND all pre-existing tests (controller, chunker, etc. that call `restore`) still green.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/pipeline.ts webapp/test/pipeline.test.ts
git commit -m "refactor(webapp): extract restoreFromPayload; restore() reuses it"
```

---

## Task 3: `RestoreController.assembledPayload`

**Files:**
- Modify: `webapp/app/controller.ts`
- Test: `webapp/test/controller.test.ts` (append)

**Interfaces:**
- Consumes: `assembleChunks` (`src/chunker.ts`), the existing private `groups` map + `ArchiveGroup` in `controller.ts`.
- Produces: `RestoreController.assembledPayload(archiveId: string): Uint8Array` — the assembled chunk payload for a detected group (pre-decrypt bytes). Throws `Error` if the archive id is unknown.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/controller.test.ts` (the file already imports `MockTransport`, `encodeChunk`, `RestoreController`, `crc32`):

```ts
test('assembledPayload returns the pre-decrypt bytes for a detected group', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, fileName: 'x.bin' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((bytes, i) => rt.enqueueTag(uid(i), bytes));
  let list = await rctrl.scanNextCard();
  for (let i = 1; i < stored.length; i++) list = await rctrl.scanNextCard();
  assert.ok(list[0]!.complete);

  const payload = rctrl.assembledPayload(list[0]!.archiveId);
  // For a plain archive the assembled payload is the filename-wrapped plaintext,
  // so it decodes back to the original data via the restore path already tested.
  const result = await rctrl.restore(list[0]!.archiveId);
  assert.ok(payload.length >= result.data.length);
});

test('assembledPayload throws for an unknown archive id', () => {
  const rctrl = new RestoreController(new MockTransport());
  assert.throws(() => rctrl.assembledPayload('does-not-exist'));
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Property 'assembledPayload' does not exist on type 'RestoreController'`.

- [ ] **Step 3: Write minimal implementation**

In `webapp/app/controller.ts`:

1. Add `assembleChunks` to the chunker import. Find the existing import block near the top; add:
```ts
import { assembleChunks } from '../src/chunker.js';
```
(If no `../src/chunker.js` import exists yet, add this new line among the other `../src/*` imports.)

2. Add the method to `RestoreController` (after `restore(...)`):
```ts
  /** Assembled chunk payload for a detected group — the pre-decrypt bytes
   *  (ciphertext when the archive is encrypted). Used to persist a Files entry. */
  assembledPayload(archiveId: string): Uint8Array {
    const group = this.groups.get(archiveId);
    if (group === undefined) throw new Error(`No detected archive ${archiveId}`);
    return assembleChunks([...group.chunks.values()]);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/controller.test.js
```
Expected: PASS — including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/controller.ts webapp/test/controller.test.ts
git commit -m "feat(webapp): RestoreController.assembledPayload for Files capture"
```

---

## Task 4: `FilesController`

**Files:**
- Create: `webapp/app/files-controller.ts`
- Test: `webapp/test/files-controller.test.ts`

**Interfaces:**
- Consumes: `FileStore`, `StoredFile`, `FileListItem`, `StorageInfo` (`src/storage/file-store.js`); `restoreFromPayload` (`src/pipeline.js`); `unwrapFilename` (`src/filename.js`); `PasswordRequiredError` (`app/controller.js`); `DecryptionError` (`src/crypto.js`); `archive` (`src/pipeline.js`) and `assembleChunks` (`src/chunker.js`) + `wrapWithFilename` (`src/filename.js`) in the test only.
- Produces:
  - `class FilesController` with:
    - `constructor(store: FileStore)`
    - `list(): Promise<FileListItem[]>` (payload stripped)
    - `info(): Promise<StorageInfo>`
    - `delete(id: string): Promise<void>`
    - `clear(): Promise<number>`
    - `saveRestored(entry: Omit<StoredFile, 'createdAt'>): Promise<void>` (stamps `createdAt = Date.now()`)
    - `prepareDownload(id: string, password?: string): Promise<{ data: Uint8Array; name: string }>`

- [ ] **Step 1: Write the failing test**

Create `webapp/test/files-controller.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryFileStore, type StoredFile } from '../src/storage/file-store.js';
import { FilesController } from '../app/files-controller.js';
import { archive } from '../src/pipeline.js';
import { assembleChunks } from '../src/chunker.js';
import { wrapWithFilename } from '../src/filename.js';
import { FLAG_COMPRESSED, FLAG_ENCRYPTED } from '../src/chunk.js';
import { PasswordRequiredError } from '../app/controller.js';
import { DecryptionError } from '../src/crypto.js';

/** Build a StoredFile entry the way restore-panel will, for `fileName`/`data`. */
async function makeEntry(
  id: string, fileName: string, data: Uint8Array, opts: { compress?: boolean; password?: string },
): Promise<Omit<StoredFile, 'createdAt'>> {
  const chunks = await archive(wrapWithFilename(data, fileName), { payloadSize: 720, ...opts });
  const flags = chunks[0]!.flags;
  return {
    id, name: fileName, size: data.length,
    isEncrypted: (flags & FLAG_ENCRYPTED) !== 0,
    isCompressed: (flags & FLAG_COMPRESSED) !== 0,
    totalChunks: chunks.length,
    payload: assembleChunks(chunks),
  };
}

test('saveRestored stamps createdAt and list() strips the payload', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('a', 'a.bin', new Uint8Array([1, 2, 3]), {}));
  const list = await ctrl.list();
  assert.equal(list.length, 1);
  assert.equal(list[0]!.name, 'a.bin');
  assert.ok(list[0]!.createdAt > 0);
  assert.equal((list[0] as Record<string, unknown>).payload, undefined);
});

test('prepareDownload round-trips a plain entry with no password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  const data = crypto.getRandomValues(new Uint8Array(300));
  await ctrl.saveRestored(await makeEntry('p', 'notes.txt', data, {}));
  const out = await ctrl.prepareDownload('p');
  assert.equal(out.name, 'notes.txt');
  assert.deepEqual(out.data, data);
});

test('prepareDownload round-trips an encrypted+compressed entry with the password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  const data = crypto.getRandomValues(new Uint8Array(400));
  await ctrl.saveRestored(await makeEntry('e', 'secret.bin', data, { compress: true, password: 'pw' }));
  const out = await ctrl.prepareDownload('e', 'pw');
  assert.deepEqual(out.data, data);
});

test('prepareDownload throws PasswordRequiredError for an encrypted entry with no password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('e', 's.bin', new Uint8Array([9]), { password: 'pw' }));
  await assert.rejects(() => ctrl.prepareDownload('e'), PasswordRequiredError);
});

test('prepareDownload throws DecryptionError for a wrong password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('e', 's.bin', new Uint8Array([9]), { password: 'pw' }));
  await assert.rejects(() => ctrl.prepareDownload('e', 'wrong'), DecryptionError);
});

test('prepareDownload throws for an unknown id', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await assert.rejects(() => ctrl.prepareDownload('nope'));
});

test('delete and clear mutate the store; info reports bytes', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('a', 'a.bin', new Uint8Array(50), {}));
  await ctrl.saveRestored(await makeEntry('b', 'b.bin', new Uint8Array(50), {}));
  const info1 = await ctrl.info();
  assert.equal(info1.count, 2);
  assert.ok(info1.totalBytes > 0);
  await ctrl.delete('a');
  assert.equal((await ctrl.list()).length, 1);
  assert.equal(await ctrl.clear(), 1);
  assert.equal((await ctrl.info()).count, 0);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Cannot find module '../app/files-controller.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/app/files-controller.ts`:

```ts
/**
 * DOM-free orchestration for the Files tab over a FileStore. Captures restored
 * archives (assembled payload + cleartext metadata) and re-derives the plaintext
 * on download, re-prompting the password for encrypted entries.
 */

import type { FileStore, StoredFile, FileListItem, StorageInfo } from '../src/storage/file-store.js';
import { restoreFromPayload } from '../src/pipeline.js';
import { unwrapFilename } from '../src/filename.js';
import { PasswordRequiredError } from './controller.js';

export class FilesController {
  constructor(private readonly store: FileStore) {}

  async list(): Promise<FileListItem[]> {
    return (await this.store.list()).map(({ payload: _payload, ...meta }) => meta);
  }

  info(): Promise<StorageInfo> {
    return this.store.info();
  }

  delete(id: string): Promise<void> {
    return this.store.delete(id);
  }

  clear(): Promise<number> {
    return this.store.clear();
  }

  saveRestored(entry: Omit<StoredFile, 'createdAt'>): Promise<void> {
    return this.store.save({ ...entry, createdAt: Date.now() });
  }

  async prepareDownload(id: string, password?: string): Promise<{ data: Uint8Array; name: string }> {
    const rec = await this.store.get(id);
    if (rec === null) throw new Error(`No stored file ${id}`);
    if (rec.isEncrypted && password === undefined) {
      throw new PasswordRequiredError('This file is encrypted; a password is required');
    }
    const wrapped = await restoreFromPayload(
      rec.payload,
      { isEncrypted: rec.isEncrypted, isCompressed: rec.isCompressed },
      password,
    );
    const { fileName, data } = unwrapFilename(wrapped);
    return { data, name: fileName ?? rec.name };
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/files-controller.test.js
```
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/files-controller.ts webapp/test/files-controller.test.ts
git commit -m "feat(webapp): FilesController (save/list/download restored archives)"
```

---

## Task 5: `files-view` reconcile renderer

**Files:**
- Create: `webapp/app/ui/files-view.ts`
- Test: `webapp/test/files-view.test.ts`

**Interfaces:**
- Consumes: `FileListItem` (`src/storage/file-store.js`).
- Produces:
  - `humanSize(bytes: number): string` — e.g. `0 B`, `512 B`, `1.5 KB`, `2.0 MB`.
  - `renderFileList(container: HTMLElement, files: FileListItem[], handlers: { onDownload: (id: string) => void; onDelete: (id: string) => void }): void` — in-place reconcile keyed by `data-file-id`; one row = `<span>` label + Download button + Delete button; rows reused across calls; rows removed when a file leaves the list.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/files-view.test.ts`. Reuse the minimal DOM-stub approach from `restore-view.test.ts` (copy the `makeDoc()` stub verbatim — it is small and this keeps the two view tests independent):

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderFileList, humanSize } from '../app/ui/files-view.js';
import type { FileListItem } from '../src/storage/file-store.js';

interface StubEl {
  tagName: string; className: string; textContent: string; disabled: boolean;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc;
  attrs: Record<string, string>; listeners: Record<string, Array<() => void>>;
  append(...k: StubEl[]): void; appendChild(k: StubEl): StubEl; remove(): void;
  setAttribute(n: string, v: string): void; getAttribute(n: string): string | null;
  addEventListener(t: string, fn: () => void): void; click(): void;
}
interface StubDoc { createElement(tag: string): StubEl; }
function makeDoc(): StubDoc {
  const doc: StubDoc = {
    createElement(tag) {
      const el: StubEl = {
        tagName: tag.toUpperCase(), className: '', textContent: '', disabled: false,
        children: [], parent: null, ownerDocument: doc, attrs: {}, listeners: {},
        append(...k) { for (const c of k) { c.parent = el; el.children.push(c); } },
        appendChild(k) { k.parent = el; el.children.push(k); return k; },
        remove() { if (el.parent) { el.parent.children.splice(el.parent.children.indexOf(el), 1); el.parent = null; } },
        setAttribute(n, v) { el.attrs[n] = v; },
        getAttribute(n) { return el.attrs[n] ?? null; },
        addEventListener(t, fn) { (el.listeners[t] ??= []).push(fn); },
        click() { for (const fn of el.listeners['click'] ?? []) fn(); },
      };
      return el;
    },
  };
  return doc;
}

const item = (over: Partial<FileListItem>): FileListItem => ({
  id: 'id-1', name: 'a.bin', size: 3, createdAt: 1000,
  isEncrypted: false, isCompressed: false, totalChunks: 1, ...over,
});

test('humanSize formats bytes/KB/MB', () => {
  assert.equal(humanSize(0), '0 B');
  assert.equal(humanSize(512), '512 B');
  assert.equal(humanSize(1536), '1.5 KB');
  assert.equal(humanSize(2 * 1024 * 1024), '2.0 MB');
});

test('renderFileList reuses row buttons across identical re-renders', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const files = [item({})];
  renderFileList(container, files, { onDownload: () => {}, onDelete: () => {} });
  const firstRow = (container as unknown as StubEl).children[0]!;
  renderFileList(container, files, { onDownload: () => {}, onDelete: () => {} });
  assert.strictEqual((container as unknown as StubEl).children[0]!, firstRow, 'row reused');
});

test('renderFileList wires Download and Delete to the row id', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const dl: string[] = []; const del: string[] = [];
  renderFileList(container, [item({ id: 'x' })], { onDownload: (id) => dl.push(id), onDelete: (id) => del.push(id) });
  const row = (container as unknown as StubEl).children[0]!;
  row.children[1]!.click(); // Download
  row.children[2]!.click(); // Delete
  assert.deepEqual(dl, ['x']);
  assert.deepEqual(del, ['x']);
});

test('renderFileList drops rows for files no longer present', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const a = item({ id: 'a' }); const b = item({ id: 'b' });
  renderFileList(container, [a, b], { onDownload: () => {}, onDelete: () => {} });
  assert.equal((container as unknown as StubEl).children.length, 2);
  renderFileList(container, [a], { onDownload: () => {}, onDelete: () => {} });
  assert.equal((container as unknown as StubEl).children.length, 1);
  assert.equal((container as unknown as StubEl).children[0]!.getAttribute('data-file-id'), 'a');
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Cannot find module '../app/ui/files-view.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/app/ui/files-view.ts`:

```ts
/**
 * Renders the stored-files list by reconciling in place: one stable row +
 * Download/Delete buttons per file id, updated on each call (like restore-view.ts),
 * so a click is never lost to a DOM teardown.
 */
import type { FileListItem } from '../../src/storage/file-store.js';

export function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function label(f: FileListItem): string {
  const when = new Date(f.createdAt).toLocaleString();
  return `${f.name}  ·  ${humanSize(f.size)}  ·  ${when}  ·  ${f.isEncrypted ? '🔒 encrypted' : 'plain'}  ·  ${f.totalChunks} card(s)`;
}

export function renderFileList(
  container: HTMLElement,
  files: FileListItem[],
  handlers: { onDownload: (id: string) => void; onDelete: (id: string) => void },
): void {
  const doc = container.ownerDocument;
  const existing = new Map<string, HTMLElement>();
  for (const row of Array.from(container.children) as HTMLElement[]) {
    const id = row.getAttribute('data-file-id');
    if (id !== null) existing.set(id, row);
  }
  const wanted = new Set(files.map((f) => f.id));
  for (const [id, row] of existing) if (!wanted.has(id)) row.remove();

  for (const f of files) {
    let row = existing.get(f.id);
    if (row === undefined) {
      row = doc.createElement('div');
      row.className = 'file';
      row.setAttribute('data-file-id', f.id);
      const span = doc.createElement('span');
      const dl = doc.createElement('button');
      dl.textContent = 'Download';
      dl.addEventListener('click', () => handlers.onDownload(f.id));
      const del = doc.createElement('button');
      del.textContent = 'Delete';
      del.addEventListener('click', () => handlers.onDelete(f.id));
      row.append(span, dl, del);
      container.appendChild(row);
      existing.set(f.id, row);
    }
    (row.children[0] as HTMLElement).textContent = label(f);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/files-view.test.js
```
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/files-view.ts webapp/test/files-view.test.ts
git commit -m "feat(webapp): files-view in-place reconcile renderer + humanSize"
```

---

## Task 6: `IdbFileStore` (IndexedDB adapter)

**Files:**
- Create: `webapp/src/storage/idb-file-store.ts`

**Interfaces:**
- Consumes: `FileStore`, `StoredFile`, `StorageInfo` (`src/storage/file-store.js`); the `indexedDB` global.
- Produces: `class IdbFileStore implements FileStore`.

**Testing note (justified exception):** `indexedDB` does not exist under `node --test`, and the spec scopes `IdbFileStore` to the manual browser checklist — its behavioral contract is fully covered by `InMemoryFileStore` (Task 1) and `FilesController` (Task 4). This task therefore has **no unit test**; it is verified by `tsc` (types + the `FileStore` contract) and by the manual browser smoke step in Task 8. Do not add a mock-IndexedDB dependency.

- [ ] **Step 1: Write the implementation**

Create `webapp/src/storage/idb-file-store.ts`:

```ts
/**
 * Persistent FileStore over IndexedDB. This is the ONLY module that touches the
 * indexedDB global (the storage fence). Records persist via structured clone, so
 * the Uint8Array payload is stored natively — no base64.
 */
import type { FileStore, StoredFile, StorageInfo } from './file-store.js';

const DB_NAME = 'nfcarchiver';
const STORE = 'files';

export class IdbFileStore implements FileStore {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private open(): Promise<IDBDatabase> {
    if (this.dbPromise === null) {
      this.dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
          if (!req.result.objectStoreNames.contains(STORE)) {
            req.result.createObjectStore(STORE, { keyPath: 'id' });
          }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error('IndexedDB open failed'));
      });
    }
    return this.dbPromise;
  }

  private async tx<T>(mode: IDBTransactionMode, fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open();
    return new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error ?? new Error('IndexedDB request failed'));
    });
  }

  async list(): Promise<StoredFile[]> {
    const all = await this.tx<StoredFile[]>('readonly', (s) => s.getAll() as IDBRequest<StoredFile[]>);
    return all.sort((a, b) => b.createdAt - a.createdAt);
  }
  async save(file: StoredFile): Promise<void> {
    await this.tx('readwrite', (s) => s.put(file));
  }
  async get(id: string): Promise<StoredFile | null> {
    const rec = await this.tx<StoredFile | undefined>('readonly', (s) => s.get(id) as IDBRequest<StoredFile | undefined>);
    return rec ?? null;
  }
  async delete(id: string): Promise<void> {
    await this.tx('readwrite', (s) => s.delete(id));
  }
  async clear(): Promise<number> {
    const count = await this.tx<number>('readonly', (s) => s.count());
    await this.tx('readwrite', (s) => s.clear());
    return count;
  }
  async info(): Promise<StorageInfo> {
    const all = await this.list();
    let totalBytes = 0;
    for (const r of all) totalBytes += r.payload.length;
    return { count: all.length, totalBytes };
  }
}
```

- [ ] **Step 2: Verify it type-checks**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
```
Expected: `tsc` clean; all existing tests still PASS (no test targets this file directly).

- [ ] **Step 3: Verify the storage fence still holds**

```bash
cd webapp && grep -rn "indexedDB" src/ app/ | grep -v "src/storage/idb-file-store.ts"
```
Expected: no output (no other module references `indexedDB`).

- [ ] **Step 4: Commit**

```bash
git add webapp/src/storage/idb-file-store.ts
git commit -m "feat(webapp): IdbFileStore IndexedDB adapter (storage fence)"
```

---

## Task 7: Files panel UI + wiring

**Files:**
- Modify: `webapp/app/index.html` (replace the Files placeholder)
- Create: `webapp/app/ui/files-panel.ts`
- Modify: `webapp/app/main.ts` (call `initFilesPanel()`)

**Interfaces:**
- Consumes: `FilesController` (`app/files-controller.js`), `IdbFileStore` (`src/storage/idb-file-store.js`), `renderFileList`/`humanSize` (`app/ui/files-view.js`), `PasswordRequiredError` (`app/controller.js`), `DecryptionError` (`src/crypto.js`), `humanError` (`app/ui/errors.js`).
- Produces: `initFilesPanel(): void`; a module-level `export const filesController = new FilesController(new IdbFileStore());` so `restore-panel` (Task 8) shares the same store.

- [ ] **Step 1: Replace the Files placeholder markup**

In `webapp/app/index.html`, replace the existing block:
```html
      <section id="panel-files" role="tabpanel" hidden>
        <div class="card"><p class="muted">No local history yet — archived files aren't stored in the browser in this version.</p></div>
      </section>
```
with:
```html
      <section id="panel-files" role="tabpanel" hidden>
        <div class="card">
          <div id="files"></div>
          <p id="files-empty" class="muted">No restored files yet. Restore an archive and it'll appear here.</p>
          <div style="margin-top:0.6rem"><span id="files-info" class="muted"></span>
            &nbsp;&nbsp;<button id="files-clear">Clear all</button></div>
          <p id="files-status" class="muted"></p>
        </div>
      </section>
```

- [ ] **Step 2: Create the panel**

Create `webapp/app/ui/files-panel.ts`:

```ts
/** Files tab: list restored archives from IndexedDB, re-download, delete, clear. */
import { FilesController } from '../files-controller.js';
import { IdbFileStore } from '../../src/storage/idb-file-store.js';
import { renderFileList, humanSize } from './files-view.js';
import { PasswordRequiredError } from '../controller.js';
import { DecryptionError } from '../../src/crypto.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

/** Shared so restore-panel can persist into the same store. */
export const filesController = new FilesController(new IdbFileStore());

async function download(id: string, setStatus: (m: string) => void): Promise<void> {
  let pw: string | undefined;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const { data, name } = await filesController.prepareDownload(id, pw);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([data as BlobPart]));
      a.download = name;
      a.click();
      URL.revokeObjectURL(a.href);
      setStatus(`Downloaded ${humanSize(data.length)} → ${name}.`);
      return;
    } catch (e) {
      if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
        const entered = prompt(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This file is encrypted. Enter password:') ?? undefined;
        if (entered === undefined) { setStatus('Cancelled.'); return; }
        pw = entered; continue;
      }
      setStatus(humanError(e));
      return;
    }
  }
  setStatus('Too many failed password attempts.');
}

export function initFilesPanel(): void {
  const setStatus = (m: string) => { $('files-status').textContent = m; };

  const refresh = async (): Promise<void> => {
    try {
      const files = await filesController.list();
      renderFileList($('files'), files, {
        onDownload: (id) => { void download(id, setStatus); },
        onDelete: async (id) => { await filesController.delete(id); await refresh(); },
      });
      const info = await filesController.info();
      $('files-empty').hidden = info.count > 0;
      $('files-info').textContent = info.count === 0 ? '' : `${info.count} file(s) · ${humanSize(info.totalBytes)} stored`;
    } catch (e) {
      setStatus(humanError(e));
    }
  };

  $('files-clear').addEventListener('click', async () => {
    if (!confirm('Delete all stored files? This cannot be undone.')) return;
    const n = await filesController.clear();
    await refresh();
    setStatus(`Cleared ${n} file(s).`);
  });

  // Refresh whenever the Files tab is opened (and once at startup).
  document.querySelector<HTMLButtonElement>('#tabs button[data-tab="files"]')!
    .addEventListener('click', () => { void refresh(); });
  void refresh();
}
```

- [ ] **Step 3: Wire it in `main.ts`**

In `webapp/app/main.ts`, add the import and the call alongside the other panels:
```ts
import { initFilesPanel } from './ui/files-panel.js';
```
and after `initRestorePanel();`:
```ts
initFilesPanel();
```

- [ ] **Step 4: Type-check, run the full suite, and build the bundle**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/files-bundle-check.js
```
Expected: `tsc` clean; all tests PASS; esbuild prints a bundle size with no errors.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/files-panel.ts webapp/app/main.ts
git commit -m "feat(webapp): Files tab UI wired to the IndexedDB store"
```

---

## Task 8: Capture restored archives into the Files store

**Files:**
- Modify: `webapp/app/ui/restore-panel.ts`

**Interfaces:**
- Consumes: `filesController` (`app/ui/files-panel.js`), `RestoreController.assembledPayload` (Task 3), the panel's existing `ctrl` (`RestoreController`), `chosenId`, and `result` (`{ data, fileName }`).
- Produces: nothing new; on a successful restore, a `StoredFile` is persisted.

- [ ] **Step 1: Add the capture call**

In `webapp/app/ui/restore-panel.ts`:

1. Add the import near the top:
```ts
import { filesController } from './files-panel.js';
```

2. In the restore success block, immediately after the existing successful-download lines (after `setStatus(\`Restored ${result.data.length} bytes → ${name}.\`);`), insert:
```ts
        // Persist a re-downloadable Files entry (non-fatal on failure — the
        // download already succeeded). Encrypted archives store ciphertext.
        try {
          const meta = ctrl.detectedArchives().find((d) => d.archiveId === chosenId);
          if (meta) {
            await filesController.saveRestored({
              id: chosenId,
              name: result.fileName ?? name,
              size: result.data.length,
              isEncrypted: meta.isEncrypted,
              isCompressed: meta.isCompressed,
              totalChunks: meta.totalChunks,
              payload: ctrl.assembledPayload(chosenId),
            });
          }
        } catch { /* history save failed; the restore/download still succeeded */ }
```

Note: `name` and `result` are already in scope in that block (see `restore-panel.ts` current success handler). Do not change the download logic itself.

- [ ] **Step 2: Type-check and run the full suite**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
```
Expected: `tsc` clean; all tests PASS (this change is UI glue; its logic — `saveRestored` + `assembledPayload` + `prepareDownload` — is covered by Tasks 3 and 4).

- [ ] **Step 3: Build the bundle**

```bash
cd webapp && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/files-bundle-check.js
```
Expected: bundle builds with no errors.

- [ ] **Step 4: Manual browser smoke (records the IndexedDB round-trip that unit tests can't)**

```bash
cd webapp && npm run app   # serves http://localhost:8000
```
On the Windows host browser (Web Bluetooth needs a real Chromium; WSL has no BT):
1. Connect the Chameleon, Restore an unencrypted archive → confirm it downloads AND appears under **Files** with name/size/date/"plain"/card count.
2. Open **Files** → **Download** the entry → file re-downloads without a prompt.
3. Restore an **encrypted** archive → appears as "🔒 encrypted"; **Download** it → prompts for the password → correct password downloads the original bytes; wrong password re-prompts.
4. Reload the page → the Files list survives (IndexedDB persistence).
5. **Delete** one entry and **Clear all** → list + footer update.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/restore-panel.ts
git commit -m "feat(webapp): capture restored archives into the Files store"
```

---

## Final verification (after all tasks)

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
grep -rn "indexedDB" src/ app/ | grep -v "src/storage/idb-file-store.ts"   # fence: expect no output
grep -rn "innerHTML" app/ui/files-panel.ts app/ui/files-view.ts            # expect no output (reconcile, not rebuild)
node -e "const p=require('./package.json'); console.log(Object.keys(p.dependencies))"  # expect ['chameleon-ultra.js']
```

Then use **superpowers:finishing-a-development-branch** to open the Files-tab PR.
