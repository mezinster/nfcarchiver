# Web NFC Scan-Model Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Web NFC reader from freezing the browser, by giving `BrowserNdefIO` one persistent scan instead of one scan per read, and by making both card loops incapable of starving the main thread.

**Architecture:** `NdefIO` gains `start()`. `BrowserNdefIO` arms exactly one `scan()` per instance, delivers each `reading` to a waiter or a short-lived buffer, and is discarded on disconnect. It also gains an injectable reader factory so the file that actually had the bug becomes testable. Both loops gain a pacing helper and a consecutive-failure breaker.

**Tech Stack:** TypeScript, esbuild, `node --test`, Web NFC (`NDEFReader`).

**Source spec:** `docs/superpowers/specs/2026-07-31-web-nfc-scan-model-fix-design.md`

## Global Constraints

- **Node >= 22.** Prefix every command with `source ~/.nvm/nvm.sh && nvm use --lts` — the shell default is Node 14.
- **Always `rm -rf dist && npm test`**, never bare `npm test`.
- All commands run from `webapp/`.
- **253 tests pass at branch start**; `tsc` clean. No new runtime dependencies, no `any`.
- **`src/` must stay importable under `node --test`** — no `NDEFReader`, `navigator`, `window` or `document` at module scope or in module-level initialisers.
- **`chameleon-ultra.js` may be imported ONLY** in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`.
- **The Chameleon path must not change behaviour.** `NtagTransport`, `AutoTransport`, `chameleon-ble.ts` and `card-layout.ts` are not touched.
- New user-facing strings go in **all seven** i18n catalogues (`en, ru, uk, be, pl, tr, ka`); `t` is a live binding, never captured at module scope.
- Commit style `fix(webapp): …` / `test(webapp): …`, ending with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## File Structure

**Created:** `src/loop-guards.ts` (pacing + breaker, pure), `test/loop-guards.test.ts`, `test/browser-ndef-io.test.ts`.

**Modified:** `src/transport/ndef-io.ts` (add `start()`), `app/ui/browser-ndef-io.ts` (rewrite), `test/fake-ndef-io.ts`, `src/transport/web-nfc-transport.ts` (`connect()`), `app/ui/device.ts`, `app/ui/restore-panel.ts`, `app/ui/archive-orchestrator.ts`, `app/i18n/*.ts` (7), `webapp/README.md`.

---

### Task 1: Loop guards

**Files:**
- Create: `src/loop-guards.ts`, `test/loop-guards.test.ts`

**Interfaces:**
- Produces: `ensureMinInterval(startedAt: number, minMs: number): Promise<void>`, `class FailureBreaker { constructor(limit?: number); record(errorName: string): boolean; reset(): void; }`

- [ ] **Step 1: Write the failing test**

Create `test/loop-guards.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ensureMinInterval, FailureBreaker } from '../src/loop-guards.js';

test('ensureMinInterval resolves immediately once the interval has passed', async () => {
  const before = Date.now();
  await ensureMinInterval(Date.now() - 500, 250);
  assert.ok(Date.now() - before < 100, 'should not have waited');
});

test('ensureMinInterval waits out the remainder', async () => {
  const before = Date.now();
  await ensureMinInterval(Date.now(), 120);
  assert.ok(Date.now() - before >= 100, 'should have waited roughly the interval');
});

test('the breaker trips after the limit of identical failures', () => {
  const b = new FailureBreaker(3);
  assert.equal(b.record('CardReadError'), false);
  assert.equal(b.record('CardReadError'), false);
  assert.equal(b.record('CardReadError'), true);
});

test('a different error name restarts the count', () => {
  const b = new FailureBreaker(3);
  b.record('CardReadError');
  b.record('CardReadError');
  assert.equal(b.record('WriteVerifyError'), false, 'a new kind of failure starts over');
  assert.equal(b.record('WriteVerifyError'), false);
});

test('reset clears the count', () => {
  const b = new FailureBreaker(2);
  b.record('CardReadError');
  b.reset();
  assert.equal(b.record('CardReadError'), false);
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — cannot find `../src/loop-guards.js`.

- [ ] **Step 3: Write the implementation**

Create `src/loop-guards.ts`:

```ts
/**
 * Guards that keep a retry loop from starving the main thread.
 *
 * A card loop retries on error. If the transport rejects instantly — as the
 * Web NFC adapter did when it re-armed an already-running scan — `continue`
 * produces an unbroken chain of already-rejected promises. Awaiting one of
 * those yields a microtask but never returns to the event loop's task queue,
 * so nothing renders and no input is handled: the browser locks up hard
 * enough that the user cannot even press Stop.
 */

/** Wait out the remainder of `minMs` since `startedAt`. */
export function ensureMinInterval(startedAt: number, minMs: number): Promise<void> {
  const remaining = minMs - (Date.now() - startedAt);
  if (remaining <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, remaining));
}

/**
 * Trips after `limit` consecutive failures of the same kind, so a loop that
 * cannot make progress stops and says why instead of retrying forever.
 *
 * Callers must not record conditions that mean "the user has not tapped yet"
 * — see the exclusion lists at each call site.
 */
export class FailureBreaker {
  constructor(private readonly limit: number = 5) {}

  private lastName: string | null = null;
  private count = 0;

  /** Record a failure. Returns true when the loop should stop. */
  record(errorName: string): boolean {
    if (errorName === this.lastName) {
      this.count += 1;
    } else {
      this.lastName = errorName;
      this.count = 1;
    }
    return this.count >= this.limit;
  }

  reset(): void {
    this.lastName = null;
    this.count = 0;
  }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, 5 new tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/loop-guards.ts webapp/test/loop-guards.test.ts
git commit -m "fix(webapp): add loop pacing and a consecutive-failure breaker"
```

---

### Task 2: `NdefIO.start()` and the fake

**Files:**
- Modify: `src/transport/ndef-io.ts`, `test/fake-ndef-io.ts`

**Interfaces:**
- Produces: `NdefIO.start(): Promise<void>`; `FakeNdefIO` gains `scanArmCount: number`, and `tap()` now resolves a waiting `awaitReading()` directly.

The fake must model the real constraint, or it cannot catch this bug: **starting twice is an error**, and `awaitReading()` never starts anything.

- [ ] **Step 1: Write the failing test**

Append to `test/web-nfc-transport.test.ts`:

```ts
test('a multi-card scan arms the reader exactly once', async () => {
  const io = new FakeNdefIO();
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  for (let i = 1; i <= 3; i++) {
    io.tap(`04:0${i}:02:03`);
    const tag = await t.awaitTag();
    assert.equal(tag.uid[1], i);
  }
  assert.equal(io.scanArmCount, 1, 'each card must reuse the one scan');
});

test('reading before the scan is started is a programming error', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  await assert.rejects(() => io.awaitReading(), /not started/i);
});

test('starting twice is rejected, as the real API does', async () => {
  const io = new FakeNdefIO();
  await io.start();
  await assert.rejects(() => io.start(), /already/i);
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — `scanArmCount` and `start` do not exist.

- [ ] **Step 3: Add `start()` to the interface**

In `src/transport/ndef-io.ts`, add to `NdefIO` above `awaitReading`:

```ts
  /** Arm the single scan. Call once, before any awaitReading(). Rejects if the
   *  browser refuses — permission denied, unsupported, or already scanning. */
  start(): Promise<void>;
```

- [ ] **Step 4: Rewrite the fake**

Replace `test/fake-ndef-io.ts` with:

```ts
import { TagTimeoutError } from '../src/transport/transport.js';
import type { NdefIO, NdefReading, NdefRecordInit } from '../src/transport/ndef-io.js';

/**
 * In-memory Web NFC, modelling the real constraint that made the shipped
 * adapter freeze the browser: exactly one scan may be armed per instance, and
 * awaitReading() never arms one. `scanArmCount` is what the regression test
 * asserts.
 */
export class FakeNdefIO implements NdefIO {
  scanArmCount = 0;
  writes: NdefRecordInit[][] = [];
  failNextWrite: Error | null = null;
  failStart: Error | null = null;

  private started = false;
  private pending: NdefReading[] = [];
  private waiter: ((r: NdefReading) => void) | null = null;
  private current: NdefReading | null = null;

  async start(): Promise<void> {
    if (this.failStart !== null) throw this.failStart;
    if (this.started) throw new Error('A scan is already in progress');
    this.started = true;
    this.scanArmCount += 1;
  }

  /** Simulate a tag entering the field. */
  tap(serialNumber: string, records: NdefReading['records'] = []): void {
    const reading: NdefReading = { serialNumber, records };
    this.current = reading;
    if (this.waiter !== null) {
      const w = this.waiter;
      this.waiter = null;
      w(reading);
      return;
    }
    this.pending.push(reading);
  }

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (!this.started) throw new Error('Scan not started');
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    const buffered = this.pending.shift();
    if (buffered !== undefined) return buffered;
    if (opts?.timeoutMs !== undefined) throw new TagTimeoutError('no tag presented');
    return new Promise<NdefReading>((resolve, reject) => {
      this.waiter = resolve;
      opts?.signal?.addEventListener('abort', () => {
        this.waiter = null;
        reject(new DOMException('Aborted', 'AbortError'));
      }, { once: true });
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    if (this.failNextWrite !== null) {
      const err = this.failNextWrite;
      this.failNextWrite = null;
      throw err;
    }
    this.writes.push(records);
    if (this.current !== null) {
      // Re-present the same tag with its new contents, as a re-tap would.
      this.tap(this.current.serialNumber, records.map((r) => ({
        recordType: r.recordType, mediaType: r.mediaType, data: r.data,
      })));
    }
  }

  stop(): void {
    this.started = false;
    this.pending = [];
    this.waiter = null;
    this.current = null;
  }
}
```

- [ ] **Step 5: Fix the callers the new contract breaks**

`awaitReading()` now throws unless `start()` ran. Every test that drives `FakeNdefIO` through a transport must `await transport.connect()` first (Task 3 wires `connect()` to `start()`; until then add `await io.start()` directly).

Run the suite and fix each failure by adding the missing `connect()`/`start()`, **not** by relaxing the fake:

```bash
cd webapp && rm -rf dist && npm test
```

Check `test/web-nfc-transport.test.ts` (including its `runTransportContract` block) and `test/archive-orchestrator.test.ts`.

- [ ] **Step 6: Verify**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS. The `scanArmCount` test passes because the fake never arms on read — the real proof comes in Task 3.

- [ ] **Step 7: Commit**

```bash
git add webapp/src/transport/ndef-io.ts webapp/test/fake-ndef-io.ts webapp/test/web-nfc-transport.test.ts webapp/test/archive-orchestrator.test.ts
git commit -m "fix(webapp): add NdefIO.start() and model the one-scan rule in the fake"
```

---

### Task 3: Rewrite `BrowserNdefIO`

**Files:**
- Modify: `app/ui/browser-ndef-io.ts`
- Create: `test/browser-ndef-io.test.ts`

**Interfaces:**
- Consumes: `NdefIO`, `NdefReading`, `NdefRecordInit`, `TagTimeoutError`, `CardCapacityError`.
- Produces: `class BrowserNdefIO implements NdefIO` with `constructor(makeReader?: () => NdefReaderLike)`, and `export interface NdefReaderLike`.

**This is the file that had the bug, and the injectable factory is what finally makes it testable.** It touches browser globals only inside function bodies, so with the factory injected the whole file imports and runs under `node --test`.

- [ ] **Step 1: Write the failing test**

Create `test/browser-ndef-io.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BrowserNdefIO, type NdefReaderLike } from '../app/ui/browser-ndef-io.js';

/** A stand-in NDEFReader that records how often a scan was armed and lets a
 *  test deliver reading events by hand. */
class FakeReader implements NdefReaderLike {
  scanCount = 0;
  onreading: ((e: { serialNumber: string; message: { records: [] } }) => void) | null = null;
  onreadingerror: ((e: unknown) => void) | null = null;
  failScan: Error | null = null;

  async scan(options: { signal: AbortSignal }): Promise<void> {
    if (this.failScan !== null) throw this.failScan;
    this.scanCount += 1;
    if (options.signal.aborted) throw new DOMException('Aborted', 'AbortError');
  }
  async write(): Promise<void> {}

  deliver(serialNumber: string): void {
    this.onreading?.({ serialNumber, message: { records: [] } });
  }
}

test('many readings are served by a single armed scan', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();

  for (let i = 1; i <= 3; i++) {
    const pending = io.awaitReading();
    reader.deliver(`04:0${i}`);
    const reading = await pending;
    assert.equal(reading.serialNumber, `04:0${i}`);
  }
  assert.equal(reader.scanCount, 1, 'the shipped bug re-armed the scan per read');
});

test('start() rejects when the browser refuses the scan', async () => {
  const reader = new FakeReader();
  reader.failScan = new DOMException('denied', 'NotAllowedError');
  const io = new BrowserNdefIO(() => reader);
  await assert.rejects(() => io.start(), /denied/);
});

test('a reading with nobody waiting is served to the next caller', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  reader.deliver('04:aa');
  assert.equal((await io.awaitReading()).serialNumber, '04:aa');
});

test('two concurrent waits are a programming error', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  const first = io.awaitReading();
  await assert.rejects(() => io.awaitReading(), /already waiting/i);
  reader.deliver('04:bb');
  await first;
});

test('stop() ends the scan and clears the buffer', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  reader.deliver('04:cc');
  io.stop();
  await assert.rejects(() => io.awaitReading(), /not started/i);
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — `BrowserNdefIO` takes no constructor argument and `NdefReaderLike` is not exported.

- [ ] **Step 3: Rewrite the implementation**

Replace the class in `app/ui/browser-ndef-io.ts` (keep the existing `NdefReadingEventLike` interface and `webNfcAvailable()`; **export** `NdefReaderLike`):

```ts
/** How long a reading with no waiter stays usable. Covers the few-millisecond
 *  gap between one card completing and the loop asking for the next; anything
 *  older would be a tap from a different moment replayed into this operation. */
const BUFFER_MS = 2000;

export class BrowserNdefIO implements NdefIO {
  /** Injectable so this file is testable under node --test, where NDEFReader
   *  does not exist. Production passes nothing. */
  constructor(
    private readonly makeReader: () => NdefReaderLike = () => {
      const Ctor = (globalThis as { NDEFReader?: new () => NdefReaderLike }).NDEFReader;
      if (Ctor === undefined) throw new Error('Web NFC is not available in this browser');
      return new Ctor();
    },
  ) {}

  private reader: NdefReaderLike | null = null;
  private scanning: AbortController | null = null;
  private waiter: { resolve: (r: NdefReading) => void; reject: (e: unknown) => void } | null = null;
  private buffered: { reading: NdefReading; at: number } | null = null;

  async start(): Promise<void> {
    if (this.reader !== null) throw new Error('A scan is already in progress');
    const reader = this.makeReader();
    const ac = new AbortController();

    reader.onreading = (event) => {
      const reading: NdefReading = {
        serialNumber: event.serialNumber ?? '',
        records: event.message.records.map((rec) => ({
          recordType: rec.recordType,
          mediaType: rec.mediaType,
          data: rec.data === undefined
            ? undefined
            : new Uint8Array(rec.data.buffer, rec.data.byteOffset, rec.data.byteLength),
        })),
      };
      const w = this.waiter;
      if (w !== null) {
        this.waiter = null;
        w.resolve(reading);
        return;
      }
      this.buffered = { reading, at: Date.now() };
    };

    reader.onreadingerror = () => {
      const w = this.waiter;
      if (w !== null) {
        this.waiter = null;
        w.reject(new Error('Could not read the tag — hold it still and try again'));
      }
    };

    // The one and only scan for this instance. Re-arming a reader is what froze
    // the browser: it rejects synchronously, and a retry loop then spins.
    await reader.scan({ signal: ac.signal });
    this.reader = reader;
    this.scanning = ac;
  }

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (this.reader === null) throw new Error('Scan not started');
    if (this.waiter !== null) throw new Error('Already waiting for a reading');
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');

    const buffered = this.buffered;
    this.buffered = null;
    if (buffered !== null && Date.now() - buffered.at <= BUFFER_MS) return buffered.reading;

    return new Promise<NdefReading>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | null = null;
      const settle = (): void => {
        if (timer !== null) clearTimeout(timer);
        opts?.signal?.removeEventListener('abort', onAbort);
        this.waiter = null;
      };
      const onAbort = (): void => { settle(); reject(new DOMException('Aborted', 'AbortError')); };

      this.waiter = {
        resolve: (r) => { settle(); resolve(r); },
        reject: (e) => { settle(); reject(e); },
      };
      opts?.signal?.addEventListener('abort', onAbort, { once: true });
      if (opts?.timeoutMs !== undefined) {
        timer = setTimeout(() => {
          settle();
          reject(new TagTimeoutError(`No tag presented within ${opts.timeoutMs}ms`));
        }, opts.timeoutMs);
      }
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    const reader = this.reader;
    if (reader === null) throw new Error('Scan not started');
    try {
      await reader.write({ records });
    } catch (e) {
      if (e instanceof DOMException &&
          (e.name === 'NotSupportedError' || e.name === 'NetworkError')) {
        throw new CardCapacityError(
          'The card rejected the write — it may be smaller than the selected tag type',
        );
      }
      throw e;
    }
  }

  stop(): void {
    this.scanning?.abort();
    this.scanning = null;
    if (this.reader !== null) {
      this.reader.onreading = null;
      this.reader.onreadingerror = null;
      this.reader = null;
    }
    this.waiter?.reject(new DOMException('Aborted', 'AbortError'));
    this.waiter = null;
    this.buffered = null;
  }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, 5 new tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/browser-ndef-io.ts webapp/test/browser-ndef-io.test.ts
git commit -m "fix(webapp): arm exactly one Web NFC scan per adapter instance"
```

---

### Task 4: Connect starts the scan

**Files:**
- Modify: `src/transport/web-nfc-transport.ts`, `app/ui/device.ts`

**Interfaces:**
- Consumes: `NdefIO.start()` (Task 2).
- Produces: `WebNfcTransport.connect()` now arms the scan; `activateWebNfc()` awaits it.

- [ ] **Step 1: Write the failing test**

Append to `test/web-nfc-transport.test.ts`:

```ts
test('connect arms the scan, and a refusal surfaces from connect', async () => {
  const ok = new FakeNdefIO();
  await new WebNfcTransport(ok, NtagType.NTAG215).connect();
  assert.equal(ok.scanArmCount, 1);

  const bad = new FakeNdefIO();
  bad.failStart = new Error('NFC permission denied');
  await assert.rejects(
    () => new WebNfcTransport(bad, NtagType.NTAG215).connect(),
    /permission denied/,
  );
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — `scanArmCount` is 0, because `connect()` is still empty.

- [ ] **Step 3: Wire the transport**

In `src/transport/web-nfc-transport.ts`, replace the empty `connect()`:

```ts
  async connect(): Promise<void> {
    // Arm the single scan here rather than lazily on first read: the permission
    // prompt then appears when the user asked for NFC, inside their gesture,
    // and a refusal surfaces at the button instead of inside a scan loop.
    await this.io.start();
  }
```

- [ ] **Step 4: Make the device bar await it**

In `app/ui/device.ts`, inside `activateWebNfc()`, replace the assignment so the transport is connected before the UI claims success:

```ts
      const t0 = new WebNfcTransport(new BrowserNdefIO(), selectedNtagType());
      await t0.connect();
      transport = t0;
```

Leave the rest of the `try` block and the existing `catch (e) { await failHandOff(...) }` untouched — the catch already tears down, re-renders, updates buttons and notifies.

- [ ] **Step 5: Verify**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add webapp/src/transport/web-nfc-transport.ts webapp/app/ui/device.ts webapp/test/web-nfc-transport.test.ts
git commit -m "fix(webapp): arm the Web NFC scan when connecting, not on first read"
```

---

### Task 5: Guards in both loops

**Files:**
- Modify: `app/ui/restore-panel.ts`, `app/ui/archive-orchestrator.ts`, `app/i18n/*.ts` (all 7)
- Test: `test/archive-orchestrator.test.ts`

**Interfaces:**
- Consumes: `ensureMinInterval`, `FailureBreaker` (Task 1).
- Produces: new i18n key `scanGaveUp`.

**The exclusions are the load-bearing part.** `TagTimeoutError` fires every 20 s with the Chameleon while the user hunts for the next card — counting it would abort a healthy archive after 90 seconds of not tapping.

- [ ] **Step 1: Add the string to all seven catalogues**

In `app/i18n/en.ts`:

```ts
  scanGaveUp: (message: string) => `Stopped after repeated failures: ${message}`,
```

Add the same key, translated, to `ru.ts`, `uk.ts`, `be.ts`, `pl.ts`, `tr.ts`, `ka.ts`. `tsc` fails until all seven have it.

- [ ] **Step 2: Write the failing test**

Append to `test/archive-orchestrator.test.ts`:

```ts
test('the write loop stops after repeated identical failures instead of spinning', async () => {
  let attempts = 0;
  const failing = {
    ...new MockTransport(),
    name: 'always-fails',
    async awaitTag() { attempts += 1; throw new CardReadError('boom'); },
  } as unknown as Transport;

  const io = makeIO(failing);
  await new ArchiveOrchestrator(io).run(failing, {
    data: new Uint8Array(50), fileName: 'x.bin', compress: false, payloadSize: 100,
  });

  assert.ok(attempts <= 6, `expected the breaker to stop it, got ${attempts} attempts`);
  assert.ok(io.statuses.some((s) => s.includes('Stopped after repeated failures')));
});
```

Adapt `makeIO` and `MockTransport` to whatever the file already uses; the assertions are what matter.

- [ ] **Step 3: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — the loop retries forever, so the test times out or `attempts` is huge.

- [ ] **Step 4: Guard the archive loop**

In `app/ui/archive-orchestrator.ts`, import `ensureMinInterval` and `FailureBreaker` from `../../src/loop-guards.js`, create `const breaker = new FailureBreaker();` before the `while (!done)` loop, and record `const iterationStart = Date.now();` as the loop's first statement.

In the `catch (e)` block, before the existing `TagTimeoutError` / `UnsupportedTagError` / `OverwriteRequiredError` branches, add pacing; and in the final catch-all branch, add the breaker:

```ts
        await ensureMinInterval(iterationStart, 250);
```

```ts
        // Waiting for the user is not failing: TagTimeoutError, an overwrite
        // prompt and an abort must never count toward the breaker.
        const name = e instanceof Error ? e.name : 'unknown';
        if (breaker.record(name)) {
          this.io.setStatus(t.scanGaveUp(humanError(e)));
          this.io.log.error('archive', 'Stopped after repeated failures', { error: String(e) });
          return;
        }
```

Call `breaker.reset()` immediately after a successful `ctrl.writeNextCard(...)`.

- [ ] **Step 5: Guard the restore loop**

In `app/ui/restore-panel.ts`, apply the same shape to the `for (;;)` loop: `const breaker = new FailureBreaker();` before it, `const iterationStart = Date.now();` as its first statement, `breaker.reset()` after a successful `scanStep`, and in the catch — after the `AbortError` break and the `TagTimeoutError` continue, both of which stay unguarded — add `await ensureMinInterval(iterationStart, 250);` plus the breaker check that sets `t.scanGaveUp(humanError(e))` and `break`s out of the loop.

- [ ] **Step 6: Verify**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/ui/restore-panel.ts webapp/app/ui/archive-orchestrator.ts webapp/app/i18n/ webapp/test/archive-orchestrator.test.ts
git commit -m "fix(webapp): pace both card loops and stop them after repeated failures"
```

---

### Task 6: Documentation

**Files:**
- Modify: `webapp/README.md`

- [ ] **Step 1: Correct the hardware-risk section**

The Readers section currently warns that `scan({signal})` may not reject on abort, leaving a pending `awaitReading()` unresolved. **That risk was wrong** — abort works; what fails is re-scanning the same reader afterwards, and that is now impossible by construction.

Replace it with what is actually true after this change: one scan is armed per connection and reused for every card; a reading arriving with no waiter is held for two seconds; both loops pace their retries and stop after five consecutive failures of the same kind. Keep the `NotSupportedError`/`NetworkError` → `CardCapacityError` note, which is still spec-derived and unverified.

State plainly what remains unproven on hardware: that `scan()` succeeds at all, and that `onreading` fires repeatedly for one persistent scan across many taps.

- [ ] **Step 2: Verify the production build**

```bash
cd webapp && rm -rf dist site && BUILD_SHA=$(git rev-parse HEAD) npm run build:site
```

Expected: `site/ built and verified — nfar-build:<sha>, bundle <N> B`.

- [ ] **Step 3: Final check**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add webapp/README.md
git commit -m "docs(webapp): correct the Web NFC scan-model risk note"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| One scan per instance, asserted by tests | 3 (real adapter), 2 (fake models the rule) |
| `start()` on the seam | 2 |
| Reading buffer, 2000 ms | 3 |
| Single waiter; concurrent wait rejects | 3 |
| Connect arms the scan; refusal surfaces at the button | 4 |
| Pacing helper, 250 ms, both loops | 1, 5 |
| Breaker, 5 identical, with exclusions | 1, 5 |
| Docs correction | 6 |

**Deviation from the spec, deliberate:** the spec did not mention an injectable reader factory. Task 3 adds one, because without it `BrowserNdefIO` — the file that actually had the bug — remains untestable, and the "regression test" would only prove the fake behaves. With injection the real class is exercised under `node --test` and `reader.scanCount === 1` is a genuine assertion about shipped code. This also partly retires the ledger note that `device.ts`-adjacent files are untestable; `device.ts` itself is still not, because of `chameleon-ultra.js`.

**Placeholder scan:** one soft spot, flagged rather than hidden — Task 5 Step 2's test must be adapted to whatever `makeIO`/`MockTransport` helpers `archive-orchestrator.test.ts` already defines, which I could not reproduce verbatim without reading that file at implementation time. The assertions are specified exactly; only the harness wiring is left to the implementer. If adapting it turns out to need more than a few lines, say so rather than reshaping the test.

**Type consistency:** `ensureMinInterval(startedAt, minMs)` and `FailureBreaker.record(errorName) → boolean` / `.reset()` are used identically in Tasks 1 and 5. `NdefIO.start(): Promise<void>` is added in Task 2 and consumed in Tasks 3 and 4. `FakeNdefIO.scanArmCount` / `.failStart` are produced in Task 2 and asserted in Tasks 2 and 4. `NdefReaderLike` is exported in Task 3 and implemented by that task's `FakeReader`.
