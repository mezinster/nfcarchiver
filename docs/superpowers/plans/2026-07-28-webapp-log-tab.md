# Web App Log Tab + Restore Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the recurring "Restore button stops working" bug by decoupling restore from the scan loop (behind a testable `RestoreOrchestrator` seam), and add a Log tab backed by a dependency-free in-memory ring-buffer logger.

**Architecture:** A dependency-free `Logger` (`src/log/logger.ts`) with an in-memory ring buffer + pub/sub. The restore/scan orchestration moves into `app/ui/restore-orchestrator.ts` behind an injected `RestoreIO` seam so it can be driven by a DOM stub + `MockTransport` in tests; `restore-panel.ts` becomes a thin adapter that builds the real IO. A `log-panel.ts` renders the Log tab. UI/glue-layer instrumentation calls `log.*`; the core codecs stay untouched.

**Tech Stack:** TypeScript (ESM, NodeNext — imports use `.js`), esbuild, `node --test`, web-platform globals (`Date.now`, `crypto.subtle`, `Blob`, `navigator.clipboard`).

## Global Constraints

- Core (`src/`) stays dependency-free and uses only web-platform globals; the logger adds no runtime dependency. `package.json` `dependencies` stays exactly `{ "chameleon-ultra.js" }`.
- ESM NodeNext: every intra-project import uses the compiled `.js` path, even from `.ts` sources.
- Tab order in `shell.ts` `TABS` and in `index.html`: `archive, restore, files, log, about` (Log before About).
- Console mirroring defaults **off** so `npm test` output stays pristine.
- Log `data` payloads never contain file contents or passwords — only ids, counts, sizes, error strings.
- Reuse the in-place reconcile renderer `renderArchiveList` (`app/ui/restore-view.ts`) and typed errors (`PasswordRequiredError` from `app/controller.ts`, `DecryptionError` from `src/crypto.ts`). Do not reintroduce `innerHTML=''` rebuilds in the restore flow (the Log list is non-interactive text, so `replaceChildren()` there is fine).
- Node ≥ 22 for tests/build: `source ~/.nvm/nvm.sh && nvm use --lts` first (shell default is Node 14). `rm -rf dist` before running tests: `rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'`.

---

## File Structure

- `src/log/logger.ts` (create) — `LogLevel`, `LogEntry`, `LEVELS`, `formatLogLine`, `Logger`, `log` singleton.
- `app/ui/restore-orchestrator.ts` (create) — `RestoreIO` interface + `RestoreOrchestrator` (scan/restore orchestration).
- `app/ui/restore-panel.ts` (rewrite) — thin adapter building the real IO + scan-step loop.
- `app/ui/log-panel.ts` (create) — Log tab glue.
- `app/ui/shell.ts` (modify) — add `'log'` to `TABS`.
- `app/index.html` (modify) — Log tab button + `#panel-log` section.
- `app/main.ts` (modify) — `initLogPanel()`.
- `app/ui/device.ts`, `app/ui/archive-panel.ts`, `app/ui/files-panel.ts` (modify) — light instrumentation.
- Tests: `test/logger.test.ts`, `test/restore-orchestrator.test.ts`.

---

## Task 1: Logger core

**Files:**
- Create: `webapp/src/log/logger.ts`
- Test: `webapp/test/logger.test.ts`

**Interfaces:**
- Consumes: nothing (leaf; web-platform globals only).
- Produces:
  - `type LogLevel = 'debug' | 'info' | 'warn' | 'error'`
  - `interface LogEntry { seq: number; t: number; level: LogLevel; cat: string; msg: string; data?: unknown; }`
  - `const LEVELS: Record<LogLevel, number>` (`debug:0, info:1, warn:2, error:3`)
  - `function formatLogLine(e: LogEntry): string`
  - `class Logger` with `debug/info/warn/error(cat, msg, data?)`, `subscribe(cb): () => void`, `snapshot(): LogEntry[]`, `clear(): void`, `setMirrorToConsole(on): void`
  - `const log: Logger` (singleton; capacity 1000, mirror off)

- [ ] **Step 1: Write the failing test**

Create `webapp/test/logger.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Logger, formatLogLine, type LogEntry } from '../src/log/logger.js';

test('formatLogLine is deterministic (UTC time, padded level)', () => {
  const e: LogEntry = { seq: 0, t: 0, level: 'info', cat: 'scan', msg: 'hi' };
  assert.equal(formatLogLine(e), '00:00:00.000 INFO  [scan] hi');
  assert.equal(formatLogLine({ ...e, level: 'error', data: { id: 'x' } }), '00:00:00.000 ERROR [scan] hi {"id":"x"}');
});

test('info appends an entry retrievable via snapshot with monotonic seq', () => {
  const log = new Logger();
  log.info('cat', 'first');
  log.warn('cat', 'second', { n: 2 });
  const s = log.snapshot();
  assert.equal(s.length, 2);
  assert.equal(s[0]!.msg, 'first');
  assert.equal(s[0]!.level, 'info');
  assert.equal(s[1]!.data && (s[1]!.data as { n: number }).n, 2);
  assert.equal(s[1]!.seq, s[0]!.seq + 1);
});

test('ring buffer evicts oldest at capacity', () => {
  const log = new Logger({ capacity: 3 });
  for (let i = 0; i < 5; i++) log.info('c', `m${i}`);
  const msgs = log.snapshot().map((e) => e.msg);
  assert.deepEqual(msgs, ['m2', 'm3', 'm4']);
});

test('subscribe fires on each append; unsubscribe stops it', () => {
  const log = new Logger();
  const seen: string[] = [];
  const off = log.subscribe((e) => seen.push(e.msg));
  log.info('c', 'a');
  off();
  log.info('c', 'b');
  assert.deepEqual(seen, ['a']);
});

test('clear empties the buffer', () => {
  const log = new Logger();
  log.info('c', 'a');
  log.clear();
  assert.equal(log.snapshot().length, 0);
});

test('a throwing subscriber does not break logging or other subscribers', () => {
  const log = new Logger();
  const seen: string[] = [];
  log.subscribe(() => { throw new Error('boom'); });
  log.subscribe((e) => seen.push(e.msg));
  assert.doesNotThrow(() => log.info('c', 'a'));
  assert.deepEqual(seen, ['a']);
});

test('console mirror is off by default and forwards when enabled', () => {
  const calls: string[] = [];
  const orig = console.info;
  console.info = (msg?: unknown) => { calls.push(String(msg)); };
  try {
    const log = new Logger();
    log.info('c', 'silent');
    assert.equal(calls.length, 0);
    log.setMirrorToConsole(true);
    log.info('c', 'loud');
    assert.equal(calls.length, 1);
  } finally {
    console.info = orig;
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Cannot find module '../src/log/logger.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/src/log/logger.ts`:

```ts
/**
 * Dependency-free in-memory event log: a capped ring buffer plus pub/sub, used
 * by the Log tab. Web-platform globals only, so it runs under node --test.
 */

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  seq: number;      // monotonic counter (stable ordering)
  t: number;        // Date.now() epoch ms
  level: LogLevel;
  cat: string;      // category, e.g. 'restore', 'scan', 'device'
  msg: string;
  data?: unknown;   // small structured context (never file contents or passwords)
}

export interface LoggerOptions { capacity?: number; mirrorToConsole?: boolean; }

export const LEVELS: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

/** Stable one-line rendering: `hh:mm:ss.mmm LEVEL [cat] msg {data}` (UTC time). */
export function formatLogLine(e: LogEntry): string {
  const time = new Date(e.t).toISOString().slice(11, 23);
  const data = e.data === undefined ? '' : ` ${JSON.stringify(e.data)}`;
  return `${time} ${e.level.toUpperCase().padEnd(5)} [${e.cat}] ${e.msg}${data}`;
}

export class Logger {
  private readonly capacity: number;
  private mirror: boolean;
  private readonly buf: LogEntry[] = [];
  private readonly subs = new Set<(e: LogEntry) => void>();
  private seq = 0;

  constructor(opts?: LoggerOptions) {
    this.capacity = opts?.capacity ?? 1000;
    this.mirror = opts?.mirrorToConsole ?? false;
  }

  private emit(level: LogLevel, cat: string, msg: string, data?: unknown): void {
    const e: LogEntry = { seq: this.seq++, t: Date.now(), level, cat, msg, ...(data !== undefined ? { data } : {}) };
    this.buf.push(e);
    if (this.buf.length > this.capacity) this.buf.shift();
    if (this.mirror) { try { console[level](formatLogLine(e)); } catch { /* ignore console failures */ } }
    for (const cb of this.subs) { try { cb(e); } catch { /* a broken subscriber must not break logging */ } }
  }

  debug(cat: string, msg: string, data?: unknown): void { this.emit('debug', cat, msg, data); }
  info(cat: string, msg: string, data?: unknown): void { this.emit('info', cat, msg, data); }
  warn(cat: string, msg: string, data?: unknown): void { this.emit('warn', cat, msg, data); }
  error(cat: string, msg: string, data?: unknown): void { this.emit('error', cat, msg, data); }

  subscribe(cb: (e: LogEntry) => void): () => void {
    this.subs.add(cb);
    return () => { this.subs.delete(cb); };
  }
  snapshot(): LogEntry[] { return [...this.buf]; }
  clear(): void { this.buf.length = 0; }
  setMirrorToConsole(on: boolean): void { this.mirror = on; }
}

export const log = new Logger();
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/logger.test.js
```
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/log/logger.ts webapp/test/logger.test.ts
git commit -m "feat(webapp): dependency-free ring-buffer Logger for the Log tab"
```

---

## Task 2: RestoreOrchestrator + DOM-stub regression test

**Files:**
- Create: `webapp/app/ui/restore-orchestrator.ts`
- Test: `webapp/test/restore-orchestrator.test.ts`

**Interfaces:**
- Consumes: `RestoreController`, `PasswordRequiredError` (`app/controller.js`); `DecryptionError` (`src/crypto.js`); `renderArchiveList` (`app/ui/restore-view.js`); `humanError` (`app/ui/errors.js`); `Transport` type (`src/transport/transport.js`); `StoredFile` type (`src/storage/file-store.js`); `Logger` type (`src/log/logger.js`). Test also uses `MockTransport` (`src/transport/mock-transport.js`) and `ArchiveController` (`app/controller.js`).
- Produces:
  - `interface RestoreIO { container: HTMLElement; files: { saveRestored(e: Omit<StoredFile,'createdAt'>): Promise<void> }; promptPassword(message: string): string | null; download(data: Uint8Array, name: string): void; fallbackName(): string; setFileName(name: string): void; setStatus(msg: string): void; log: Logger; }`
  - `class RestoreOrchestrator` with `constructor(io: RestoreIO)`, `startSession(transport: Transport): void`, `scanStep(signal: AbortSignal): Promise<void>`, `restoreArchive(id: string): Promise<void>`.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/restore-orchestrator.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { ArchiveController } from '../app/controller.js';
import { RestoreOrchestrator, type RestoreIO } from '../app/ui/restore-orchestrator.js';
import { Logger } from '../src/log/logger.js';

/** Minimal DOM stub (as in restore-view.test.ts) — but click() is async and
 *  awaits handler return values, so a button click that triggers an async
 *  restore can be awaited deterministically in the test. */
interface StubEl {
  tagName: string; className: string; textContent: string; disabled: boolean;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc;
  attrs: Record<string, string>; listeners: Record<string, Array<() => unknown>>;
  append(...k: StubEl[]): void; appendChild(k: StubEl): StubEl; remove(): void;
  setAttribute(n: string, v: string): void; getAttribute(n: string): string | null;
  addEventListener(t: string, fn: () => unknown): void; click(): Promise<void>;
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
        async click() { for (const fn of el.listeners['click'] ?? []) await fn(); },
      };
      return el;
    },
  };
  return doc;
}

const uidFor = (a: number) => (i: number) => new Uint8Array([a, 0, 0, i]);

/** Archive `data` to mock cards and return the stored bytes per card. */
async function archiveToCards(data: Uint8Array, opts: { compress: boolean; password?: string; fileName: string }): Promise<Uint8Array[]> {
  const src = new MockTransport();
  const ctrl = new ArchiveController(src);
  const uid = uidFor(0xa0);
  const total = await ctrl.prepare({ data, fileName: opts.fileName, compress: opts.compress, password: opts.password, payloadSize: 720 });
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i)); await ctrl.writeNextCard();
    src.enqueueTag(uid(i)); await src.awaitTag(); stored.push(await src.readChunk());
  }
  return stored;
}

function makeIO(container: StubEl, over?: Partial<RestoreIO>) {
  const downloads: Array<{ data: Uint8Array; name: string }> = [];
  const saved: Array<{ id: string; isEncrypted: boolean }> = [];
  const io: RestoreIO = {
    container: container as unknown as HTMLElement,
    files: { async saveRestored(e) { saved.push({ id: e.id, isEncrypted: e.isEncrypted }); } },
    promptPassword: () => null,
    download: (data, name) => downloads.push({ data, name }),
    fallbackName: () => 'restored.bin',
    setFileName: () => {},
    setStatus: () => {},
    log: new Logger(),
    ...over,
  };
  return { io, downloads, saved };
}

const signal = () => new AbortController().signal;

test('restore works for multiple archives, repeatedly, independent of the scan loop', async () => {
  const plain = crypto.getRandomValues(new Uint8Array(1500));   // multi-card, incompressible
  const secret = crypto.getRandomValues(new Uint8Array(1500));
  const cardsA = await archiveToCards(plain, { compress: false, fileName: 'a.bin' });
  const cardsB = await archiveToCards(secret, { compress: false, password: 'pw', fileName: 'b.bin' });

  const doc = makeDoc();
  const container = doc.createElement('div');
  const { io, downloads, saved } = makeIO(container, { promptPassword: () => 'pw' });
  const orch = new RestoreOrchestrator(io);

  const rt = new MockTransport();
  orch.startSession(rt);
  cardsA.forEach((b, i) => rt.enqueueTag(new Uint8Array([1, 0, 0, i]), b));
  cardsB.forEach((b, i) => rt.enqueueTag(new Uint8Array([2, 0, 0, i]), b));
  // Drive detection deterministically (MockTransport.awaitTag throws when idle,
  // so we never run the panel's unbounded loop).
  for (let i = 0; i < cardsA.length + cardsB.length; i++) await orch.scanStep(signal());

  const rows = (container as unknown as StubEl).children;
  assert.equal(rows.length, 2, 'both archives detected as rows');
  const btn = (rowIdx: number) => rows[rowIdx]!.children[1]!; // [span, Restore button]

  // Click archive A's Restore button -> restores the plain archive.
  await btn(0).click();
  assert.equal(downloads.length, 1);
  assert.deepEqual(downloads[0]!.data, plain);
  assert.equal(downloads[0]!.name, 'a.bin');

  // Click archive B's button -> encrypted, promptPassword supplies 'pw'.
  await btn(1).click();
  assert.equal(downloads.length, 2);
  assert.deepEqual(downloads[1]!.data, secret);

  // Regression: click archive A AGAIN -> restores a second time (the pre-fix
  // one-shot handler restored only once; a dead re-click would leave length 2).
  await btn(0).click();
  assert.equal(downloads.length, 3);
  assert.deepEqual(downloads[2]!.data, plain);

  // Restore-after-"stop": no scanStep in between, direct call still works.
  await orch.restoreArchive(rows[1]!.getAttribute('data-archive-id')!);
  assert.equal(downloads.length, 4);
  assert.deepEqual(downloads[3]!.data, secret);

  assert.ok(saved.some((s) => !s.isEncrypted) && saved.some((s) => s.isEncrypted), 'both saved to history');
});

test('restoreArchive ignores a wrong-then-cancelled password without downloading', async () => {
  const secret = crypto.getRandomValues(new Uint8Array(800));
  const cards = await archiveToCards(secret, { compress: false, password: 'pw', fileName: 's.bin' });
  const doc = makeDoc();
  const container = doc.createElement('div');
  // First prompt returns a wrong password, second returns null (cancel).
  const answers = ['nope', null] as Array<string | null>;
  const { io, downloads } = makeIO(container, { promptPassword: () => answers.shift() ?? null });
  const orch = new RestoreOrchestrator(io);
  const rt = new MockTransport();
  orch.startSession(rt);
  cards.forEach((b, i) => rt.enqueueTag(new Uint8Array([3, 0, 0, i]), b));
  for (let i = 0; i < cards.length; i++) await orch.scanStep(signal());
  await (container as unknown as StubEl).children[0]!.children[1]!.click();
  assert.equal(downloads.length, 0, 'cancelled restore downloads nothing');
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc
```
Expected: FAIL — `Cannot find module '../app/ui/restore-orchestrator.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/app/ui/restore-orchestrator.ts`:

```ts
/**
 * DOM-light restore/scan orchestration behind an injected IO seam. Restoring is
 * decoupled from the scan loop: each rendered Restore button calls
 * restoreArchive(id) directly, so it works during a scan, after Stop, and
 * repeatedly for different archives. The panel supplies the real DOM/browser IO;
 * tests supply a DOM stub + MockTransport.
 */
import { RestoreController, PasswordRequiredError } from '../controller.js';
import { DecryptionError } from '../../src/crypto.js';
import { renderArchiveList } from './restore-view.js';
import { humanError } from './errors.js';
import type { Transport } from '../../src/transport/transport.js';
import type { StoredFile } from '../../src/storage/file-store.js';
import type { Logger } from '../../src/log/logger.js';

export interface RestoreIO {
  container: HTMLElement;
  files: { saveRestored(e: Omit<StoredFile, 'createdAt'>): Promise<void> };
  promptPassword(message: string): string | null;
  download(data: Uint8Array, name: string): void;
  fallbackName(): string;
  setFileName(name: string): void;
  setStatus(msg: string): void;
  log: Logger;
}

export class RestoreOrchestrator {
  private ctrl: RestoreController | null = null;
  private restoring = false;

  constructor(private readonly io: RestoreIO) {}

  private render(list: Parameters<typeof renderArchiveList>[1]): void {
    renderArchiveList(this.io.container, list, (id) => this.restoreArchive(id));
  }

  startSession(transport: Transport): void {
    this.ctrl = new RestoreController(transport);
    this.render([]); // clear any rows from a previous session
    this.io.log.info('scan', 'Session started');
  }

  async scanStep(signal: AbortSignal): Promise<void> {
    if (this.ctrl === null) throw new Error('scanStep before startSession');
    const list = await this.ctrl.scanNextCard(signal);
    this.render(list);
    this.io.log.debug('scan', 'Detection', { archives: list.length, complete: list.filter((d) => d.complete).length });
  }

  async restoreArchive(id: string): Promise<void> {
    if (this.ctrl === null) { this.io.log.warn('restore', 'Ignored: no session', { id }); return; }
    if (this.restoring) { this.io.log.warn('restore', 'Ignored: already restoring', { id }); return; }
    const ctrl = this.ctrl;
    this.restoring = true;
    this.io.log.info('restore', 'Restore clicked', { id });
    try {
      let pw: string | undefined;
      let result: { data: Uint8Array; fileName: string | null } | undefined;
      for (let attempt = 0; attempt < 5; attempt++) {
        try { result = await ctrl.restore(id, pw); break; }
        catch (e) {
          if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
            const entered = this.io.promptPassword(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:');
            if (entered === null) { this.io.setStatus('Cancelled.'); this.io.log.info('restore', 'Cancelled', { id }); return; }
            pw = entered; continue;
          }
          throw e;
        }
      }
      if (!result) { this.io.setStatus('Too many failed password attempts.'); this.io.log.warn('restore', 'Too many password attempts', { id }); return; }
      const name = result.fileName ?? this.io.fallbackName();
      if (result.fileName) this.io.setFileName(result.fileName);
      this.io.download(result.data, name);
      this.io.setStatus(`Restored ${result.data.length} bytes → ${name}.`);
      this.io.log.info('restore', 'Restored', { id, bytes: result.data.length, name });
      try {
        const meta = ctrl.detectedArchives().find((d) => d.archiveId === id);
        if (meta) {
          await this.io.files.saveRestored({
            id, name: result.fileName ?? name, size: result.data.length,
            isEncrypted: meta.isEncrypted, isCompressed: meta.isCompressed,
            totalChunks: meta.totalChunks, payload: ctrl.assembledPayload(id),
          });
          this.io.log.info('files', 'Saved to history', { id });
        }
      } catch (e) {
        this.io.log.warn('files', 'History save failed (non-fatal)', { id, error: String(e) });
      }
    } catch (e) {
      this.io.setStatus(humanError(e));
      this.io.log.error('restore', 'Restore failed', { id, error: String(e) });
    } finally {
      this.restoring = false;
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/restore-orchestrator.test.js
```
Expected: PASS — 2 tests (multi-restore + cancelled-password).

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/restore-orchestrator.ts webapp/test/restore-orchestrator.test.ts
git commit -m "feat(webapp): RestoreOrchestrator decouples restore from the scan loop (+ DOM-stub regression test)"
```

---

## Task 3: restore-panel.ts thin adapter

**Files:**
- Rewrite: `webapp/app/ui/restore-panel.ts`

**Interfaces:**
- Consumes: `RestoreOrchestrator`, `RestoreIO` (`app/ui/restore-orchestrator.js`); `TagTimeoutError`, `UnsupportedTagError` (`src/transport/transport.js`); `currentTransport`, `onConnectionChange` (`app/ui/device.js`); `filesController` (`app/ui/files-panel.js`); `humanError` (`app/ui/errors.js`); `log` (`src/log/logger.js`).
- Produces: `initRestorePanel(): void` (unchanged signature; `main.ts` already calls it).

- [ ] **Step 1: Replace the file**

Overwrite `webapp/app/ui/restore-panel.ts` with:

```ts
/** Restore tab: thin adapter — builds the DOM/browser IO for RestoreOrchestrator and runs the scan-step loop. */
import { RestoreOrchestrator, type RestoreIO } from './restore-orchestrator.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { currentTransport, onConnectionChange } from './device.js';
import { filesController } from './files-panel.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

export function initRestorePanel(): void {
  const setStatus = (msg: string) => { $('restore-status').textContent = msg; };
  let scanAbort: AbortController | null = null;

  const io: RestoreIO = {
    container: $('archives'),
    files: filesController,
    promptPassword: (message) => window.prompt(message),
    download: (data, name) => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([data as BlobPart]));
      a.download = name;
      a.click();
      URL.revokeObjectURL(a.href);
    },
    fallbackName: () => ($('fname') as HTMLInputElement).value || 'restored.bin',
    setFileName: (name) => { ($('fname') as HTMLInputElement).value = name; },
    setStatus,
    log,
  };
  const orch = new RestoreOrchestrator(io);

  onConnectionChange((connected) => {
    ($('scan') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus('Scan a pile of cards to detect archives.');
  });

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    orch.startSession(transport);
    scanAbort = new AbortController();
    ($('scan') as HTMLButtonElement).disabled = true;
    ($('stop-scan') as HTMLButtonElement).disabled = false;
    setStatus('Scanning — tap cards on the reader…');
    log.info('scan', 'Scan started');
    try {
      for (;;) {
        try {
          await orch.scanStep(scanAbort.signal);
          setStatus('Tap more cards, or Restore a complete one.');
        } catch (e) {
          if (e instanceof DOMException && e.name === 'AbortError') break;
          if (e instanceof TagTimeoutError) continue;
          if (e instanceof UnsupportedTagError) { setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); log.warn('scan', 'Unsupported tag'); continue; }
          setStatus(`Skipped a card: ${humanError(e)}`);
          log.warn('scan', 'Skipped a card', { error: String(e) });
          continue;
        }
      }
    } finally {
      ($('stop-scan') as HTMLButtonElement).disabled = true;
      ($('scan') as HTMLButtonElement).disabled = false;
      log.info('scan', 'Scan stopped');
    }
  });

  $('stop-scan').addEventListener('click', () => { scanAbort?.abort(); });
}
```

- [ ] **Step 2: Type-check, run the full suite, and build the bundle**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/log-bundle-check.js
```
Expected: `tsc` clean; all tests pass (logger + orchestrator + all pre-existing); esbuild prints a size with no errors. (This task is UI glue; its restore logic is covered by Task 2's orchestrator test and the button-click reliability by `restore-view.test.ts`.)

- [ ] **Step 3: Commit**

```bash
git add webapp/app/ui/restore-panel.ts
git commit -m "refactor(webapp): restore-panel is a thin adapter over RestoreOrchestrator"
```

---

## Task 4: Log tab UI + wiring

**Files:**
- Create: `webapp/app/ui/log-panel.ts`
- Modify: `webapp/app/ui/shell.ts` (add `'log'` to `TABS`)
- Modify: `webapp/app/index.html` (Log tab button + `#panel-log` section)
- Modify: `webapp/app/main.ts` (`initLogPanel()`)

**Interfaces:**
- Consumes: `log`, `formatLogLine`, `LEVELS`, `LogEntry`, `LogLevel` (`src/log/logger.js`).
- Produces: `initLogPanel(): void`.

- [ ] **Step 1: Add `'log'` to the tab list**

In `webapp/app/ui/shell.ts`, change:
```ts
const TABS = ['archive', 'restore', 'files', 'about'] as const;
```
to:
```ts
const TABS = ['archive', 'restore', 'files', 'log', 'about'] as const;
```

- [ ] **Step 2: Add the Log tab button + panel markup**

In `webapp/app/index.html`, add the tab button after the `files` button (line ~80):
```html
        <button role="tab" data-tab="log" aria-selected="false">Log</button>
```
(so the order is Archive, Restore, Files, Log, About).

And add this section immediately after the `#panel-files` `</section>` (before `#panel-about`):
```html
      <section id="panel-log" role="tabpanel" hidden>
        <div class="card">
          <div style="display:flex;gap:0.6rem;flex-wrap:wrap;align-items:center">
            <label>level
              <select id="log-level">
                <option value="debug">debug</option>
                <option value="info" selected>info</option>
                <option value="warn">warn</option>
                <option value="error">error</option>
              </select>
            </label>
            <label><input type="checkbox" id="log-autoscroll" checked /> auto-scroll</label>
            <label><input type="checkbox" id="log-console" /> mirror to console</label>
            <button id="log-clear">Clear</button>
            <button id="log-copy">Copy</button>
            <button id="log-download">Download</button>
          </div>
          <div id="log" style="font-family:monospace;font-size:0.8rem;max-height:60vh;overflow:auto;white-space:pre-wrap;margin-top:0.6rem"></div>
        </div>
      </section>
```

- [ ] **Step 3: Create the panel**

Create `webapp/app/ui/log-panel.ts`:

```ts
/** Log tab: live view of the in-app event log with min-level filter + export. */
import { log, formatLogLine, LEVELS, type LogEntry, type LogLevel } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

export function initLogPanel(): void {
  const box = $('log');
  const levelSel = $('log-level') as HTMLSelectElement;
  const autoscroll = $('log-autoscroll') as HTMLInputElement;
  const consoleChk = $('log-console') as HTMLInputElement;
  const minLevel = (): number => LEVELS[levelSel.value as LogLevel] ?? 0;

  const addRow = (e: LogEntry): void => {
    const row = document.createElement('div');
    row.dataset['level'] = e.level;
    row.textContent = formatLogLine(e);
    row.hidden = LEVELS[e.level] < minLevel();
    box.appendChild(row);
    if (autoscroll.checked) box.scrollTop = box.scrollHeight;
  };

  const rerender = (): void => {
    box.replaceChildren(); // log rows are non-interactive text — safe to rebuild
    for (const e of log.snapshot()) addRow(e);
  };

  rerender();
  log.subscribe(addRow);

  levelSel.addEventListener('change', () => {
    const min = minLevel();
    for (const row of Array.from(box.children) as HTMLElement[]) {
      const lvl = row.dataset['level'] as LogLevel | undefined;
      row.hidden = lvl === undefined ? false : LEVELS[lvl] < min;
    }
  });
  consoleChk.addEventListener('change', () => log.setMirrorToConsole(consoleChk.checked));
  $('log-clear').addEventListener('click', () => { log.clear(); rerender(); });
  $('log-copy').addEventListener('click', () => {
    void navigator.clipboard?.writeText(log.snapshot().map(formatLogLine).join('\n'));
  });
  $('log-download').addEventListener('click', () => {
    const text = log.snapshot().map(formatLogLine).join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    a.download = `nfc-archiver-log-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  });
}
```

- [ ] **Step 4: Wire it in `main.ts`**

In `webapp/app/main.ts`, add the import:
```ts
import { initLogPanel } from './ui/log-panel.js';
```
and call it after `initFilesPanel();`:
```ts
initLogPanel();
```

- [ ] **Step 5: Type-check, run the suite, build the bundle**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/log-bundle-check.js
```
Expected: `tsc` clean; all tests pass; bundle builds. (Panel is glue; `formatLogLine` is unit-tested in Task 1.)

- [ ] **Step 6: Commit**

```bash
git add webapp/app/ui/log-panel.ts webapp/app/ui/shell.ts webapp/app/index.html webapp/app/main.ts
git commit -m "feat(webapp): Log tab (live event view, level filter, copy/download)"
```

---

## Task 5: Instrumentation (device, archive, files)

**Files:**
- Modify: `webapp/app/ui/device.ts`, `webapp/app/ui/archive-panel.ts`, `webapp/app/ui/files-panel.ts`

**Interfaces:**
- Consumes: `log` (`src/log/logger.js`). No new produced interface.

- [ ] **Step 1: Instrument `device.ts` connect**

Add the import near the top of `webapp/app/ui/device.ts` (with the other `./` imports):
```ts
import { log } from '../../src/log/logger.js';
```
In the `$('connect')` click handler, add logging around the existing body:
```ts
  $('connect').addEventListener('click', async () => {
    log.info('device', 'Connecting');
    try {
      ultra = new ChameleonUltra();
      await ultra.use(new WebbleAdapter());
      transport = new AutoTransport(new SdkChameleonDevice(ultra));
      await transport.connect();
      $('conn').textContent = 'connected';
      ($('diagnose') as HTMLButtonElement).disabled = false;
      for (const cb of listeners) cb(true);
      deviceStatus.textContent = 'Connected.';
      log.info('device', 'Connected');
    } catch (e) {
      deviceStatus.textContent = humanError(e);
      log.error('device', 'Connect failed', { error: String(e) });
    }
  });
```

- [ ] **Step 2: Instrument `archive-panel.ts`**

Add the import near the top of `webapp/app/ui/archive-panel.ts`:
```ts
import { log } from '../../src/log/logger.js';
```
The write handler is `$('archive').click`: it calls `const total = await ctrl.prepare({ ... })` (line 80), then a `while (!done) { … }` loop (lines 83-99), then a `} catch (e) { … }` (line 100). Add two log lines, at exact anchors:

1. Immediately **after** the `const total = await ctrl.prepare({ ... });` line and its following `render(0, total, false);`:
```ts
      log.info('archive', 'Prepared', { cards: total });
```
2. Immediately **after** the closing brace of the `while (!done) { … }` loop (i.e. between the loop's `}` and the `} catch (e) {`), where the archive is fully written:
```ts
      log.info('archive', 'Write complete', { cards: total });
```
Do not change any control flow.

- [ ] **Step 3: Instrument `files-panel.ts`**

Add the import near the top of `webapp/app/ui/files-panel.ts`:
```ts
import { log } from '../../src/log/logger.js';
```
In the module-level `download(id, setStatus)` function, after the successful `setStatus(\`Downloaded ...\`)` line, add:
```ts
      log.info('files', 'Downloaded', { id, name });
```
In `initFilesPanel`, in the `onDelete` handler, after `await filesController.delete(id);` add:
```ts
        log.info('files', 'Deleted', { id });
```
In the `$('files-clear')` handler, after `const n = await filesController.clear();` add:
```ts
    log.info('files', 'Cleared', { count: n });
```

- [ ] **Step 4: Type-check, run the suite, build the bundle**

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/log-bundle-check.js
```
Expected: `tsc` clean; all tests pass; bundle builds.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/device.ts webapp/app/ui/archive-panel.ts webapp/app/ui/files-panel.ts
git commit -m "feat(webapp): instrument device/archive/files panels with log events"
```

---

## Final verification (after all tasks)

```bash
cd webapp && rm -rf dist && npx tsc && node --test 'dist/test/**/*.test.js'   # all pass
npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/log-bundle-check.js  # builds
node -e "console.log(Object.keys(require('./package.json').dependencies))"        # ['chameleon-ultra.js']
grep -rn "innerHTML" app/ui/restore-panel.ts app/ui/restore-orchestrator.ts       # expect no output
```

**Manual browser smoke (Windows-host Chromium + Chameleon):** connect; scan a pile of 5–6 archives; open the **Log** tab and confirm events stream (scan started, detections, restore clicked/restored); restore archive A then B then A again from one scan **without rescanning** — all succeed; hit **Stop**, then restore another — succeeds; use **Copy**/**Download** to export the trace. This is the acceptance test for the decoupling fix.

Then use **superpowers:finishing-a-development-branch** to open the PR (base `master`).
