# Resilient webapp archive write flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the webapp's multi-card archive write survive a bad/misplaced card (retry, never abort) and a reader disconnect (pause, then resume the same session on reconnect).

**Architecture:** Extract the write loop from the `archive-panel.ts` click handler into a DOM-free `ArchiveOrchestrator` behind an injected `ArchiveIO` seam, mirroring the existing `RestoreOrchestrator`. The loop exits only when all chunks are written; every per-card error retries, and a disconnect pauses on `await io.awaitReconnect()` then swaps a fresh transport into the controller via a new `ArchiveController.setTransport()`. `device.ts` gains the missing disconnect sensor.

**Tech Stack:** TypeScript + esbuild, `node --test`, dependency-free core (`chameleon-ultra.js` stays confined to `device.ts` / `sdk-chameleon-device.ts`).

## Global Constraints

- **Node ≥ 22 via nvm.** Before any npm/node command: `source ~/.nvm/nvm.sh && nvm use --lts` (default shell Node is 14).
- **Run tests with a clean build:** `rm -rf dist && npm test` (the `tsc && node --test` chain does not clean stale compiled tests). Run from `webapp/`.
- **Dependency fence:** `chameleon-ultra.js` may be imported ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`. The orchestrator and controller stay SDK-free.
- **On-tag byte format is unchanged.** No touching chunk/NDEF/filename encoding.
- **No localization** — webapp has no l10n; user-facing strings are inline English.
- **Existing `ArchiveController` public surface must not break:** constructor `new ArchiveController(transport)` and `writeNextCard(signal?, confirmOverwrite?)` are used by 7 call-sites in `test/controller.test.ts` and must keep working.

---

### Task 1: `ArchiveController.setTransport()`

Add the ability to swap the transport on a live controller without losing session state. This is what lets a paused write resume on a freshly-built transport after reconnect.

**Files:**
- Modify: `webapp/app/controller.ts` (class `ArchiveController`, around lines 65-122)
- Test: `webapp/test/controller.test.ts` (append one test)

**Interfaces:**
- Consumes: existing `ArchiveController`, `MockTransport`, `Transport`.
- Produces: `ArchiveController.setTransport(t: Transport): void` — replaces the transport used by subsequent `writeNextCard` calls; leaves `chunks`, `written`, `writtenUids`, `payloadSize` untouched.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/controller.test.ts`:

```ts
test('setTransport swaps the transport mid-session and preserves written state', async () => {
  const t1 = new MockTransport();
  const ctrl = new ArchiveController(t1);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  assert.ok(total >= 3, `need >=3 cards, got ${total}`);

  // Write the first two cards on t1.
  t1.enqueueTag(uid(0)); await ctrl.writeNextCard();
  t1.enqueueTag(uid(1)); const afterTwo = await ctrl.writeNextCard();
  assert.equal(afterTwo.progress.written, 2);

  // Swap in a fresh transport; the controller must resume at chunk index 2.
  const t2 = new MockTransport();
  ctrl.setTransport(t2);
  t2.enqueueTag(uid(2));
  const afterSwap = await ctrl.writeNextCard();
  assert.equal(afterSwap.progress.written, 3, 'continues counting from the preserved state');

  // The chunk written on t2 is card index 2 (distinct UID, real NFAR bytes).
  t2.enqueueTag(uid(2)); await t2.awaitTag();
  const stored = decodeChunk(await t2.readChunk());
  assert.equal(stored.chunkIndex, 2, 'wrote the correct next chunk after the swap');
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts && cd webapp && rm -rf dist && npm test 2>&1 | grep -A3 'setTransport swaps'
```
Expected: FAIL — `ctrl.setTransport is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `webapp/app/controller.ts`, change the `transport` from a `readonly` constructor param to a mutable field and add the setter. Replace the constructor line:

```ts
  constructor(private readonly transport: Transport) {}
```
with:
```ts
  private transport: Transport;
  constructor(transport: Transport) { this.transport = transport; }

  /** Swap the transport used by subsequent writeNextCard calls. Session state
   *  (chunks, written count, written UIDs, payload size) is preserved — used to
   *  resume a paused write on a freshly-built transport after a reconnect. */
  setTransport(t: Transport): void { this.transport = t; }
```

(All existing `this.transport.*` references inside the class are unchanged.)

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -20
```
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver && git add webapp/app/controller.ts webapp/test/controller.test.ts && \
git commit -m "$(cat <<'EOF'
feat(webapp): ArchiveController.setTransport for reconnect-safe resume

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `ArchiveOrchestrator` — retry-only per-card resilience

Extract the write loop into a DOM-free orchestrator behind an IO seam. This task delivers the core "a bad card never aborts the session" behavior. Disconnect handling is added in Task 3.

**Files:**
- Create: `webapp/app/ui/archive-orchestrator.ts`
- Test: `webapp/test/archive-orchestrator.test.ts` (create)

**Interfaces:**
- Consumes: `ArchiveController`, `ArchiveRequest`, `OverwriteRequiredError` from `../controller.js`; `TagTimeoutError`, `UnsupportedTagError`, `Transport` from `../../src/transport/transport.js`; `humanError` from `./errors.js`; `Logger` from `../../src/log/logger.js`.
- Produces:
  - `interface ArchiveIO { setStatus(msg: string): void; showProgress(label: string, value: number | null, max: number): void; hideProgress(): void; confirmOverwrite(): boolean; isConnected(): boolean; awaitReconnect(): Promise<Transport>; log: Logger; }`
  - `class ArchiveOrchestrator { constructor(io: ArchiveIO); run(transport: Transport, req: ArchiveRequest): Promise<void>; }`
  - `run` resolves only when every chunk is written; it never rejects for a per-card failure.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/archive-orchestrator.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { WriteVerifyError, type PresentedTag, type Transport } from '../src/transport/transport.js';
import { ArchiveOrchestrator, type ArchiveIO } from '../app/ui/archive-orchestrator.js';
import { Logger } from '../src/log/logger.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
const multiCardData = crypto.getRandomValues(new Uint8Array(2000)); // incompressible -> many cards

/** Wraps a MockTransport and throws WriteVerifyError on the Nth writeChunk (1-based). */
class FlakyWriteTransport implements Transport {
  readonly name = 'flaky';
  private writes = 0;
  constructor(private readonly inner: MockTransport, private readonly failOnWrite: number) {}
  connect() { return this.inner.connect(); }
  disconnect() { return this.inner.disconnect(); }
  awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> { return this.inner.awaitTag(opts); }
  peekIsNfar() { return this.inner.peekIsNfar(); }
  readChunk() { return this.inner.readChunk(); }
  async writeChunk(bytes: Uint8Array): Promise<void> {
    this.writes += 1;
    if (this.writes === this.failOnWrite) throw new WriteVerifyError('simulated verify failure');
    return this.inner.writeChunk(bytes);
  }
}

function makeIO(over?: Partial<ArchiveIO>) {
  const statuses: string[] = [];
  let hidden = false;
  const io: ArchiveIO = {
    setStatus: (m) => statuses.push(m),
    showProgress: () => {},
    hideProgress: () => { hidden = true; },
    confirmOverwrite: () => true,
    isConnected: () => true,
    awaitReconnect: async () => { throw new Error('awaitReconnect should not be called in this test'); },
    log: new Logger(),
    ...over,
  };
  return { io, statuses, wasHidden: () => hidden };
}

test('a bad card retries instead of aborting the whole session', async () => {
  const inner = new MockTransport();
  const { io, wasHidden } = makeIO();
  const orch = new ArchiveOrchestrator(io);

  // The 2nd write fails (card yanked / verify mismatch), then the same card is re-tapped.
  const t = new FlakyWriteTransport(inner, 2);
  const req = { data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 };

  // Pre-tap enough cards: one extra tap of card index 1 covers the retry.
  const total = 3; // multiCardData at 720 B/chunk => 3 cards
  inner.enqueueTag(uid(0));
  inner.enqueueTag(uid(1)); // this write fails
  inner.enqueueTag(uid(1)); // re-tap same card -> retry succeeds
  inner.enqueueTag(uid(2));

  await orch.run(t, req);

  assert.equal(wasHidden(), false, 'progress is never hidden — the session did not abort');
  // All three distinct cards hold real NFAR chunks now.
  for (let i = 0; i < total; i++) {
    inner.enqueueTag(uid(i)); await inner.awaitTag();
    assert.ok((await inner.readChunk()).length > 0, `card ${i} written`);
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | grep -iE 'archive-orchestrator|Cannot find'
```
Expected: FAIL — module `../app/ui/archive-orchestrator.js` not found.

- [ ] **Step 3: Write minimal implementation**

Create `webapp/app/ui/archive-orchestrator.ts`:

```ts
/**
 * DOM-free archive write loop behind an injected IO seam, mirroring
 * RestoreOrchestrator. The loop NEVER aborts on a per-card failure: any error
 * from writing one card leaves the session state intact and prompts a re-tap.
 * A reader disconnect pauses on awaitReconnect() and resumes the same session
 * on a fresh transport (see setTransport on the controller). The panel supplies
 * real DOM/browser IO; tests supply a stub IO + MockTransport.
 */
import { ArchiveController, OverwriteRequiredError, type ArchiveRequest } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError, type Transport } from '../../src/transport/transport.js';
import { humanError } from './errors.js';
import type { Logger } from '../../src/log/logger.js';

export interface ArchiveIO {
  setStatus(msg: string): void;
  showProgress(label: string, value: number | null, max: number): void;
  hideProgress(): void;
  confirmOverwrite(): boolean;
  isConnected(): boolean;
  awaitReconnect(): Promise<Transport>;
  log: Logger;
}

export class ArchiveOrchestrator {
  constructor(private readonly io: ArchiveIO) {}

  private render(written: number, total: number, done: boolean): void {
    this.io.showProgress(
      done ? `✓ ${written} of ${total} cards written & verified`
           : `✓ ${written} of ${total} written & verified — tap the next card`,
      written, total,
    );
    this.io.setStatus(done
      ? `Done — wrote and verified ${written} card(s).`
      : `Tap card ${written + 1} of ${total} on the reader…`);
  }

  async run(transport: Transport, req: ArchiveRequest): Promise<void> {
    const ctrl = new ArchiveController(transport);
    let total = await ctrl.prepare(req);
    this.render(0, total, false);
    this.io.log.info('archive', 'Prepared', { cards: total });

    let done = false;
    while (!done) {
      if (!this.io.isConnected()) {
        this.io.setStatus('Reader disconnected — reconnect to resume.');
        this.io.log.warn('archive', 'Reader disconnected — awaiting reconnect');
        ctrl.setTransport(await this.io.awaitReconnect());
        this.io.log.info('archive', 'Reconnected — resuming');
        continue;
      }
      try {
        const res = await ctrl.writeNextCard();
        total = res.progress.total;
        done = res.done;
        this.render(res.progress.written, total, done);
        if (res.rechunkedTo) {
          this.io.setStatus(`Card holds ${res.rechunkedTo.payloadSize} B/chunk — writing ${res.rechunkedTo.total} card(s) instead.`);
        }
      } catch (e) {
        if (!this.io.isConnected()) continue; // disconnect — handled at the loop top
        if (e instanceof TagTimeoutError) { this.io.setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
        if (e instanceof UnsupportedTagError) { this.io.setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); continue; }
        if (e instanceof OverwriteRequiredError) {
          if (this.io.confirmOverwrite()) {
            try {
              const res = await ctrl.writeNextCard(undefined, true);
              total = res.progress.total;
              done = res.done;
              this.render(res.progress.written, total, done);
            } catch (e2) {
              if (!this.io.isConnected()) continue;
              this.io.setStatus(`${humanError(e2)} — re-tap to retry.`);
              this.io.log.warn('archive', 'Overwrite write failed — will retry', { error: String(e2) });
            }
          } else {
            this.io.setStatus('Skipped. Tap a different card…');
          }
          continue;
        }
        // Any other per-card failure (verify/auth/capacity/mid-write I-O): retry, never abort.
        this.io.setStatus(`${humanError(e)} — re-tap to retry.`);
        this.io.log.warn('archive', 'Card write failed — will retry', { error: String(e) });
        continue;
      }
    }
    this.io.log.info('archive', 'Write complete', { cards: total });
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | grep -A2 'bad card retries'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver && git add webapp/app/ui/archive-orchestrator.ts webapp/test/archive-orchestrator.test.ts && \
git commit -m "$(cat <<'EOF'
feat(webapp): ArchiveOrchestrator with retry-only per-card resilience

A bad or misplaced card no longer aborts the multi-card write; the loop
retries the same chunk on the next tap and only exits when all cards are
written.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Pause & resume on reader disconnect

Prove and lock in the disconnect path: when the injected IO reports a disconnect, the loop pauses on `awaitReconnect()`, swaps the fresh transport into the controller, and resumes at the correct chunk — with a byte-identical restore of the finished set.

**Files:**
- Modify: `webapp/test/archive-orchestrator.test.ts` (append one test; the disconnect logic already exists in the orchestrator from Task 2)

**Interfaces:**
- Consumes: `ArchiveOrchestrator`, `ArchiveIO`, `MockTransport`, `RestoreController` from `../app/controller.js`, `decodeChunk` unnecessary (RestoreController reads cards).

- [ ] **Step 1: Write the failing test**

First confirm the resume path is exercised. Append to `webapp/test/archive-orchestrator.test.ts`:

```ts
import { RestoreController } from '../app/controller.js';

test('a disconnect pauses and resumes the same session on a fresh transport', async () => {
  const original = crypto.getRandomValues(new Uint8Array(2000)); // 3 cards at 720 B
  const tA = new MockTransport();
  const tB = new MockTransport();

  let connected = true;
  let reconnects = 0;
  const io: ArchiveIO = {
    setStatus: () => {},
    // Drop the connection right after the 2nd card is verified.
    showProgress: (_label, value) => { if (value === 2 && connected) connected = false; },
    hideProgress: () => { throw new Error('must not hide progress — session must not abort'); },
    confirmOverwrite: () => true,
    isConnected: () => connected,
    awaitReconnect: async () => { connected = true; reconnects += 1; return tB; },
    log: new Logger(),
  };

  // tA presents cards 0 and 1; tB presents the remaining cards after reconnect.
  tA.enqueueTag(uid(0));
  tA.enqueueTag(uid(1));
  for (let i = 2; i < 8; i++) tB.enqueueTag(uid(i)); // plenty for the remainder

  const orch = new ArchiveOrchestrator(io);
  await orch.run(tA, { data: original, fileName: 'blob.bin', compress: false, payloadSize: 720 });

  assert.equal(reconnects, 1, 'resumed exactly once');

  // Reassemble from the cards actually written across BOTH transports.
  const restoreT = new MockTransport();
  const readBack = async (t: MockTransport, n: number) => {
    t.enqueueTag(uid(n)); await t.awaitTag(); return t.readChunk();
  };
  restoreT.enqueueTag(uid(0), await readBack(tA, 0));
  restoreT.enqueueTag(uid(1), await readBack(tA, 1));
  restoreT.enqueueTag(uid(2), await readBack(tB, 2));

  const rctrl = new RestoreController(restoreT);
  let detected = await rctrl.scanNextCard(new AbortController().signal);
  detected = await rctrl.scanNextCard(new AbortController().signal);
  detected = await rctrl.scanNextCard(new AbortController().signal);
  assert.equal(detected.length, 1);
  assert.equal(detected[0]!.complete, true, 'all 3 chunks present across the two transports');

  const { data } = await rctrl.restore(detected[0]!.archiveId, undefined);
  assert.deepEqual(data, original, 'resumed session restores byte-identically');
});
```

- [ ] **Step 2: Run test to verify it passes (logic already present)**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | grep -A2 'disconnect pauses and resumes'
```
Expected: PASS (the orchestrator's disconnect branch from Task 2 handles it). If it FAILS, fix the orchestrator's loop-top `isConnected()` / `awaitReconnect()` / `setTransport()` sequence until green — this test is the specification for that path.

- [ ] **Step 3: Commit**

```bash
cd /home/mezinster/nfcarchiver && git add webapp/test/archive-orchestrator.test.ts && \
git commit -m "$(cat <<'EOF'
test(webapp): disconnect pauses and resumes archive write byte-identically

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Disconnect sensor in `device.ts`

Wire the real disconnect signal so the panel's `awaitReconnect` can ever resolve and buttons reflect the true connection state. `device.ts` imports the SDK and is not unit-tested; verification is type-check + code review + (if hardware available) a manual smoke test.

**Files:**
- Modify: `webapp/app/ui/device.ts`

**Interfaces:**
- Consumes: `ChameleonUltra` (`.emitter.on('disconnected', …)`, per the SDK dts: "`disconnected`: Emitted when device is disconnected").
- Produces: `isConnected(): boolean` export; `onConnectionChange` listeners now also receive `false` on disconnect; `currentTransport()` returns `null` while disconnected.

- [ ] **Step 1: Add the connection flag and export**

In `webapp/app/ui/device.ts`, add a module-level flag next to the existing `let transport` (line ~20):

```ts
let connected = false;
```

Add an exported accessor next to `currentTransport` (line ~23):

```ts
export function isConnected(): boolean {
  return connected;
}
```

- [ ] **Step 2: Set the flag on connect and wire the disconnect event**

In the `$('connect')` click handler, immediately after `ultra = new ChameleonUltra();`, attach the disconnect listener:

```ts
      ultra = new ChameleonUltra();
      // Fires when the BLE link drops (device powered off, out of range, GATT
      // lost). Flip connection state, drop the dead transport, and notify
      // listeners so the archive loop can pause and later resume.
      ultra.emitter.on('disconnected', () => {
        connected = false;
        transport = null;
        ($('diagnose') as HTMLButtonElement).disabled = true;
        $('conn').textContent = 'disconnected';
        deviceStatus.textContent = 'Reader disconnected — click Connect to resume.';
        log.warn('device', 'Disconnected');
        for (const cb of listeners) cb(false);
      });
```

Then in the same handler, after the existing successful-connect lines (`$('conn').textContent = 'connected';` … `for (const cb of listeners) cb(true);`), set the flag. Add immediately before `for (const cb of listeners) cb(true);`:

```ts
      connected = true;
```

(If `ultra.emitter.on(...)` produces a TypeScript error about the event name or listener type, cast the event arg: `ultra.emitter.on('disconnected' as never, () => { … })`. Do not change any SDK types.)

- [ ] **Step 3: Type-check / build**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -15
```
Expected: `tsc` compiles with no errors and the full suite stays green (this change adds no new tests but must not break compilation).

- [ ] **Step 4: Code-review checklist (manual, no automated test — device.ts imports the SDK)**

Confirm by reading the diff:
- `connected` is set `true` only on a fully successful connect, and `false` in the `disconnected` handler.
- `transport` is nulled in the `disconnected` handler (so `currentTransport()` returns `null` while down).
- Listeners receive `cb(false)` on disconnect and `cb(true)` on (re)connect.
- The dependency fence holds: the only new SDK usage is `ultra.emitter.on` inside `device.ts`.

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver && git add webapp/app/ui/device.ts && \
git commit -m "$(cat <<'EOF'
feat(webapp): detect Chameleon BLE disconnect and expose isConnected

Wires ultra.emitter 'disconnected' to flip connection state, drop the dead
transport, and notify onConnectionChange listeners — the sensor the archive
pause/resume loop needs.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `archive-panel.ts` to the orchestrator

Replace the inline `while (!done)` loop with the orchestrator, supplying real DOM/browser IO — including `awaitReconnect` built on `onConnectionChange` and `confirmOverwrite` via `window.confirm`. This is the integration task; after it, the feature works end-to-end in the browser.

**Files:**
- Modify: `webapp/app/ui/archive-panel.ts` (replace the `$('archive').addEventListener('click', …)` body, lines ~69-118; keep the source/counter/`selectedPayloadSize` code above it)

**Interfaces:**
- Consumes: `ArchiveOrchestrator`, `ArchiveIO` from `./archive-orchestrator.js`; `isConnected`, `currentTransport`, `onConnectionChange` from `./device.js`; `log` from `../../src/log/logger.js`.
- Produces: no exports change (`initArchivePanel` stays the entry point).

- [ ] **Step 1: Update imports**

At the top of `webapp/app/ui/archive-panel.ts`, replace:

```ts
import { ArchiveController, OverwriteRequiredError } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
```
with:
```ts
import { ArchiveOrchestrator, type ArchiveIO } from './archive-orchestrator.js';
import type { Transport } from '../../src/transport/transport.js';
```

And update the device import to include `isConnected`:

```ts
import { currentTransport, isConnected, onConnectionChange } from './device.js';
```

- [ ] **Step 2: Replace the click handler body**

Replace the entire `$('archive').addEventListener('click', async () => { … });` block (the `try { … prepare … while(!done) … } catch { hideProgress(); setStatus(humanError(e)); }`) with:

```ts
  $('archive').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const src = currentSource();
    if (!src) { setStatus('Pick a file or type some text first.'); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const pass = ($('apass') as HTMLInputElement).value;

    const io: ArchiveIO = {
      setStatus,
      showProgress,
      hideProgress,
      confirmOverwrite: () => window.confirm('This card already holds data. Overwrite it?'),
      isConnected,
      // Resolve with the freshly-built transport the next time we connect.
      awaitReconnect: () => new Promise<Transport>((resolve) => {
        const off = onConnectionChange((connected) => {
          const t = currentTransport();
          if (connected && t) { off(); resolve(t); }
        });
      }),
      log,
    };

    ($('archive') as HTMLButtonElement).disabled = true;
    try {
      await new ArchiveOrchestrator(io).run(transport, {
        data: src.data, fileName: src.fileName, compress,
        password: pass || undefined, payloadSize: selectedPayloadSize(),
      });
    } finally {
      ($('archive') as HTMLButtonElement).disabled = !isConnected();
    }
  });
```

- [ ] **Step 3: Make `onConnectionChange` return an unsubscribe function**

`awaitReconnect` above calls `off()` to detach its one-shot listener. Update `onConnectionChange` in `webapp/app/ui/device.ts`. Replace:

```ts
export function onConnectionChange(cb: (connected: boolean) => void): void {
  listeners.push(cb);
}
```
with:
```ts
export function onConnectionChange(cb: (connected: boolean) => void): () => void {
  listeners.push(cb);
  return () => {
    const i = listeners.indexOf(cb);
    if (i >= 0) listeners.splice(i, 1);
  };
}
```

(Existing callers in `restore-panel.ts` and `archive-panel.ts`'s own `onConnectionChange((connected) => …)` at line ~64 ignore the return value — still valid.)

- [ ] **Step 4: Verify the existing panel-level connection listener still compiles**

The pre-existing `onConnectionChange((connected) => { ($('archive') …).disabled = !connected; … })` near line 64 is unchanged and now also fires on disconnect (disabling the button) — desired. Leave it as is.

- [ ] **Step 5: Build, type-check, full test suite**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -20
```
Expected: `tsc` clean, ALL tests pass (controller + archive-orchestrator + restore-orchestrator + the rest).

- [ ] **Step 6: Manual smoke (if a Chameleon + browser on the Windows host is available)**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm run app
```
In Chromium on the Windows host, open `localhost:8000`:
1. Connect the Chameleon, pick a small file that spans ≥3 cards.
2. Mid-write, pull a card away early → status shows "…re-tap to retry", progress is NOT lost; re-tap completes that card.
3. Present a wrong-format card → "Unsupported tag…", loop continues.
4. Power off the Chameleon mid-write → "Reader disconnected — reconnect to resume"; power on + Connect → writing resumes from the next card. Finishes to "Done".

(Skip if no hardware; the automated tests cover the logic. Note in the PR that the manual smoke was or wasn't run.)

- [ ] **Step 7: Commit**

```bash
cd /home/mezinster/nfcarchiver && git add webapp/app/ui/archive-panel.ts webapp/app/ui/device.ts && \
git commit -m "$(cat <<'EOF'
feat(webapp): drive archive write via ArchiveOrchestrator (retry + resume)

The archive panel is now a thin adapter: a bad/misplaced card retries and a
reader disconnect pauses then resumes on reconnect, instead of aborting the
whole multi-card session. onConnectionChange returns an unsubscribe fn for the
one-shot reconnect wait.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Retry-only per-card failure → Task 2 (orchestrator generic-error branch) + test; wrong-format already handled and preserved (`UnsupportedTagError` branch). ✓
- Pause & resume on disconnect → Task 1 (`setTransport`) + Task 2 (loop-top pause branch) + Task 3 (resume test) + Task 4 (disconnect sensor) + Task 5 (`awaitReconnect` wiring). ✓
- "Loop exits only on done" → orchestrator has no path that rethrows out of the loop; only `done` ends it. ✓
- Disconnect detection was missing → Task 4. ✓
- Byte format unchanged → no chunk/NDEF/filename edits anywhere. ✓
- Controller public surface preserved → Task 1 keeps constructor + `writeNextCard` signature; only adds `setTransport`. ✓
- Edge cases (partial-write overwrite prompt, `CardAuthError` retry, idempotent first-card rechunk) → all fall through the generic retry branch or the existing overwrite/unsupported branches; no special code needed, consistent with spec's "acceptable" notes. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every command has expected output. ✓

**Type consistency:** `ArchiveIO` shape identical in Task 2 definition, Task 3 test, and Task 5 wiring (`setStatus`, `showProgress(label,value,max)`, `hideProgress`, `confirmOverwrite(): boolean`, `isConnected(): boolean`, `awaitReconnect(): Promise<Transport>`, `log`). `ArchiveOrchestrator.run(transport, req)` used identically in tests and panel. `setTransport(t)` defined in Task 1, called in Task 2 orchestrator. `onConnectionChange` return type changed in Task 5 Step 3 and only its new return value is consumed (by `awaitReconnect`); existing callers ignore it. ✓
