# Web App Files Tab — IndexedDB Archive Store — Design

**Status:** approved (brainstorm) — 2026-07-28

**Goal:** Turn the web app's placeholder **Files** tab into a working local history of
restored archives, persisted in the browser via IndexedDB, mirroring the Android app's
persistent-storage model. Each entry is re-downloadable; encrypted archives are stored as
ciphertext and re-decrypted with the password on download.

## Context

The Flutter app has two on-disk JSON/file stores under the app documents directory:

- `SessionStorageService` — persists in-progress restore sessions as `<uuid>.json` in
  `NFC_Sessions/` (`lib/features/restore/data/session_storage_service.dart`).
- `FileManagerRepository` — the Files screen, listing restored files in `NFC_Archives/`
  with count/size + delete/delete-all (`lib/features/file_manager/data/file_manager_repository.dart`).

The web app's Files tab is currently a placeholder: *"No local history yet — archived files
aren't stored in the browser in this version."* (`webapp/app/index.html`). A browser tab cannot
write to the OS filesystem (`/tmp`), so the web-native equivalent of those JSON files is an
**IndexedDB object store**: it persists structured records (including binary `Uint8Array`
payloads via structured clone) across reloads with no server.

## Decisions (locked during brainstorming)

1. **Storage:** IndexedDB, in-browser. No server, no OS files.
2. **Record model:** metadata **+ payload** (re-downloadable), not a metadata-only log.
3. **Capture point:** **Restore only.** An entry is written when a restore succeeds. Archiving
   to cards does not write a Files entry.
4. **Encrypted archives:** store the **assembled ciphertext** (encrypted at rest). Download
   re-prompts for the password and re-runs decrypt/decompress. Only the file **content** is
   encrypted; **metadata** (name, size, card count, date, flags) is stored in the clear so the
   list is browsable without a password.

### Why storing the assembled payload gives ciphertext for free

The NFAR archive pipeline layers as `wrapWithFilename → (gzip) → (AES-256-GCM encrypt) → chunk`
(`webapp/src/pipeline.ts`, `webapp/app/controller.ts`). Restore reverses it:
`assembleChunks → (decrypt) → (gunzip) → unwrapFilename`. The output of `assembleChunks` — the
bytes *before* decryption — is therefore exactly the encrypted blob (`salt + IV + ciphertext +
tag`) for an encrypted archive, or the (compressed-or-plain) filename-wrapped bytes for an
unencrypted one. Storing that assembled payload:

- encrypts content at rest whenever the archive was encrypted, with no re-encryption step;
- is uniform — download always runs the same pipeline tail on the stored bytes.

The filename lives *inside* the encrypted layer, so it cannot be derived from stored ciphertext
without the password. It is therefore captured as **cleartext metadata** at restore time (when the
user has just decrypted successfully and the plaintext filename is known).

## Architecture

Follows the existing **seam + in-memory fake** pattern (as with `ChameleonDevice`/`FakeChameleon`
and `Transport`/`MockTransport`), so controllers are unit-testable under `node --test`, where
`indexedDB` does not exist.

```
webapp/
  src/storage/
    file-store.ts        # StoredFile type + FileStore interface + InMemoryFileStore (core, dep-free, tested)
    idb-file-store.ts    # IdbFileStore implements FileStore over the indexedDB global (browser-only; the ONLY file that touches IndexedDB)
  app/
    files-controller.ts  # DOM-free: list/save/delete/clear/info + prepareDownload(id, password?) (tested vs InMemoryFileStore)
  app/ui/
    files-view.ts        # in-place reconcile renderer for the file rows (tested with a DOM stub, like restore-view.ts)
    files-panel.ts       # DOM glue: wires files-controller + files-view, download/delete/clear, storage footer
    restore-panel.ts     # MODIFIED: after a successful restore, save the entry into the store
```

### Record model (`src/storage/file-store.ts`)

```ts
export interface StoredFile {
  id: string;           // archive UUID string (primary key; upsert de-dupes re-restores of the same archive)
  name: string;         // recovered filename (cleartext metadata)
  size: number;         // plaintext byte length, for display
  createdAt: number;    // epoch ms when saved
  isEncrypted: boolean; // from NFAR flags
  isCompressed: boolean;// from NFAR flags
  totalChunks: number;  // card count
  payload: Uint8Array;  // assembled chunk payload: ciphertext if encrypted, else wrapped(+gzip) plaintext
}

export interface StorageInfo { count: number; totalBytes: number; }

export interface FileStore {
  list(): Promise<StoredFile[]>;            // newest-first (createdAt desc)
  save(file: StoredFile): Promise<void>;    // upsert by id
  get(id: string): Promise<StoredFile | null>;
  delete(id: string): Promise<void>;
  clear(): Promise<number>;                 // returns number deleted
  info(): Promise<StorageInfo>;
}
```

`totalBytes` sums stored `payload.length` (the on-disk cost), independent of the displayed
plaintext `size`. `InMemoryFileStore` backs the record with a `Map<string, StoredFile>` and is the
store used by all controller/unit tests.

### IndexedDB adapter (`src/storage/idb-file-store.ts`)

- Database `nfcarchiver`, object store `files`, `keyPath: 'id'`.
- Opens lazily; creates the store in `onupgradeneeded` (version 1).
- Each method wraps a transaction; `list()` reads all and sorts newest-first; `info()` derives
  count + summed `payload.length`.
- Payloads persist as `Uint8Array` via structured clone (no base64).
- This file is the **only** place `indexedDB` is referenced — the storage fence, analogous to the
  SDK fence for `chameleon-ultra.js`.

### Files controller (`app/files-controller.ts`)

DOM-free orchestration over a `FileStore`:

- `list()`, `info()`, `delete(id)`, `clear()` — pass-throughs returning view data.
- `saveRestored(entry)` — build a `StoredFile` (stamp `createdAt = Date.now()`) and `save`.
- `prepareDownload(id, password?)` — load the record; if `isEncrypted` and `password` is
  undefined, throw `PasswordRequiredError` (defined in `app/controller.ts`, re-exported for reuse);
  otherwise call `restoreFromPayload(payload, { isEncrypted, isCompressed }, password)` — which
  throws `DecryptionError` on a wrong password — then `unwrapFilename(...)` the result and return
  `{ data, name }` (the unwrapped name equals the stored metadata `name`). Unencrypted entries need
  no password.

A helper `restoreFromPayload(payload, { isEncrypted, isCompressed }, password?)` in
`src/pipeline.ts` performs the assembled-payload tail — **decrypt → decompress** (it returns the
still-filename-wrapped bytes, exactly like `pipeline.restore` does; `unwrapFilename` stays at the
caller). Both the existing chunk-based `restore()` and the Files controller share it (DRY):
`restore(chunks, pw)` becomes `restoreFromPayload(assembleChunks(chunks), { isEncrypted: flags &
FLAG_ENCRYPTED, isCompressed: flags & FLAG_COMPRESSED }, pw)` where `flags = chunks[0].flags`.
`restoreFromPayload` throws `DecryptionError` (from `src/crypto.ts`) on an absent/wrong key for an
encrypted payload — matching today's `pipeline.restore`; the friendlier "password required"
distinction is raised one level up (see below).

### Restore capture (`app/ui/restore-panel.ts`)

On a successful restore, before/after triggering the download, persist the entry. The panel already
holds the chosen archive's `DetectedArchive` (id, flags, totalChunks) and the restore `result`
(data, fileName). To obtain the **assembled payload**, `RestoreController` gains a method
`assembledPayload(archiveId): Uint8Array` that returns `assembleChunks([...group.chunks.values()])`
for the group — the pre-decrypt bytes. The panel then calls
`filesController.saveRestored({ id, name, size: result.data.length, isEncrypted, isCompressed,
totalChunks, payload })`.

Save failures are non-fatal: the download still succeeds; a save error only sets a status note.

### Files view (`app/ui/files-view.ts`) and panel (`app/ui/files-panel.ts`)

`files-view.ts` reuses the **in-place reconcile** approach introduced in `restore-view.ts`: one
stable row per `id`, keyed by `data-file-id`, updated in place, listeners bound once — so Download
and Delete buttons are never torn down under a click. Each row shows:

`name · humanSize(size) · date · 🔒 encrypted|plain · N card(s)` with **Download** and **Delete**
buttons. Row callbacks: `onDownload(id)`, `onDelete(id)`.

`files-panel.ts`:

- On tab activation (and after any mutation) calls `filesController.list()` + `info()` and renders.
- **Download:** `prepareDownload(id)`; on `PasswordRequiredError`/`DecryptionError`, `prompt()` for
  the password and retry (same retry loop shape as restore-panel), then trigger a Blob download.
- **Delete:** `filesController.delete(id)` then re-render.
- **Clear all:** confirm, `filesController.clear()`, re-render.
- Footer: `"{count} file(s) · {humanSize(totalBytes)} stored"`; empty state message when count is 0.

The panel is wired in `app/main.ts` alongside the other panels. The Files tab markup in
`app/index.html` replaces the placeholder with a container (`#files`) + footer (`#files-info`).

## Data flow

**Capture:** scan cards → pick archive → `RestoreController.restore(id, pw)` decrypts →
download triggered → `saveRestored` stores `{ metadata + assembled payload }` in IndexedDB.

**Re-download:** Files tab → Download → `prepareDownload(id, pw?)` → (decrypt/decompress/unwrap) →
Blob download. Encrypted entries prompt for the password; the stored payload stays ciphertext.

**Manage:** Delete removes one record; Clear all empties the store; footer shows count + bytes.

## Error handling

- `prepareDownload` reuses `PasswordRequiredError` (encrypted + no password; from
  `app/controller.ts`) and `DecryptionError` (wrong password; from `src/crypto.ts`) — the Files
  panel's password retry loop mirrors restore-panel's.
- IndexedDB open/transaction failures reject the `FileStore` promise; the panel surfaces a status
  message via `humanError` and leaves the UI usable. A capture-time save failure never blocks the
  restore download.
- `list()`/`info()` on a fresh browser (store empty) return `[]` / `{count:0,totalBytes:0}`.

## Testing

- `src/storage/file-store.ts` `InMemoryFileStore`: save/list newest-first, upsert by id, get,
  delete, clear (returns count), info (count + summed payload length).
- `app/files-controller.ts` vs `InMemoryFileStore`: `saveRestored` stamps `createdAt`;
  `prepareDownload` round-trips a plain entry (no password), an encrypted entry (correct password →
  bytes; missing → `PasswordRequiredError`; wrong → `DecryptionError`), and a compressed entry.
- `app/ui/files-view.ts` with a DOM stub (as in `restore-view.test.ts`): row reuse across
  re-renders, Download/Delete callbacks fire with the right id, rows removed when a file leaves the
  list.
- End-to-end (in-memory): archive → cards → restore → `saveRestored` → `prepareDownload` returns
  byte-identical data and filename, for both a plain and an encrypted+compressed archive.
- `IdbFileStore` is browser-only (no `indexedDB` under `node --test`); it is exercised via the
  manual hardware/browser checklist, not unit tests — the `FileStore` contract it implements is
  fully covered by `InMemoryFileStore`.

## Out of scope (YAGNI)

- Persisting **in-progress** (incomplete) scan sessions — capture is restore-only; the scan pile is
  transient. (The Android `SessionStorageService` resume feature is not ported here.)
- Capturing archives you write to cards (archive-side history).
- Renaming entries, folders/tags, search, quota/eviction handling, cross-device sync.
- Encrypting the metadata at rest.

## Global constraints

- Core (`src/`) stays dependency-free and uses only web-platform globals; `indexedDB` is confined to
  `src/storage/idb-file-store.ts`. No new runtime dependencies.
- On-tag byte formats and the NFAR pipeline are unchanged; this feature only reads assembled
  payloads and stores them locally.
- Node ≥ 22 for tests/build; `rm -rf dist` before `npm test`.
- Reuse existing errors (`PasswordRequiredError`, `DecryptionError`) and the in-place reconcile
  render pattern; do not reintroduce `innerHTML = ''` list rebuilds.
