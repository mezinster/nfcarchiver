# Web App Log Tab + Restore Decoupling — Design

**Status:** approved (brainstorm) — 2026-07-28

**Goal:** (1) Fix the recurring "Restore button stops working" bug by decoupling the restore action from the scan loop, and (2) add a **Log** tab that records the app's internal UI/glue events in an in-memory ring buffer so behavior is observable and shareable.

## Motivation

The Restore tab's buttons stop responding intermittently — reported after restoring one archive and after finishing a scan of several archives. Root cause (confirmed by reading `webapp/app/ui/restore-panel.ts`): the entire restore lifecycle lives inside a single `$('scan')` click handler. The Restore buttons' `onPick(id)` only sets a local `pickedId` and aborts the scan loop; the actual restore runs once *after* the loop breaks, then the handler returns. Consequences:

- Only **one** archive can be restored per Scan click.
- After that restore completes — or after **Stop** — the handler has returned. The archive rows remain (the in-place reconcile keeps their buttons alive), but their `onPick` now points at a finished handler: it sets `pickedId` on a dead closure and aborts an already-aborted controller. Clicking Restore does nothing.

This is an architectural coupling, not a flaky timing issue. The `RestoreController` already restores from in-memory chunks (no transport needed), so restore does not need the scan loop at all. Two fixes were already tried on this button (skip blank cards; in-place reconcile so buttons aren't torn down); this third change addresses the actual root cause, and the Log tab makes the fix self-verifying and helps with the genuinely hardware-flaky cases (RF/tag detection) that can't be reproduced without the device.

## Decisions (locked during brainstorming)

1. **Bundle** the restore decoupling fix and the Log tab in one iteration; the refactored restore flow is instrumented from birth.
2. **In-memory ring buffer** (~1000 entries, cleared on reload) + **export** (Copy to clipboard, Download `.txt`). No cross-reload persistence (this bug is within-session; matches the app's client-only, no-storage ethos).
3. Instrument at the **UI/glue layer** (panels + `device.ts`). The dependency-free core codecs stay untouched.

## Architecture

Four pieces, following existing patterns (dependency-free `src/` core + thin DOM glue in `app/`).

```
webapp/
  src/log/
    logger.ts           # dependency-free Logger (ring buffer + pub/sub) + `log` singleton; unit-tested under node
  app/ui/
    log-panel.ts             # subscribes to `log`, renders the Log tab, Clear/Copy/Download/level-filter/auto-scroll
    restore-orchestrator.ts  # NEW: DOM-light restore/scan orchestration behind an injected IO seam (unit-tested with a DOM stub)
    restore-panel.ts         # MODIFIED: thin IO adapter — builds the real DOM/browser IO, wires Scan/Stop, runs the scan-step loop
    device.ts                # MODIFIED: log connect/disconnect
    archive-panel.ts    # MODIFIED (light): log archive prepare/write-complete
    files-panel.ts      # MODIFIED (light): log download/delete/clear
    shell.ts            # MODIFIED: add 'log' to the TABS tuple
  app/
    index.html          # MODIFIED: add the Log tab button + panel section
    main.ts             # MODIFIED: initLogPanel()
```

### Logger core (`src/log/logger.ts`)

Dependency-free, web-platform globals only (`Date.now`), so it runs under `node --test` like the rest of `src/`.

```ts
export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  seq: number;      // monotonic counter (stable ordering + de-dupe in the panel)
  t: number;        // Date.now() epoch ms
  level: LogLevel;
  cat: string;      // category, e.g. 'restore', 'scan', 'device'
  msg: string;
  data?: unknown;   // small structured context, e.g. { id, count }
}

export interface LoggerOptions { capacity?: number; mirrorToConsole?: boolean; }

export class Logger {
  constructor(opts?: LoggerOptions);            // default capacity 1000, mirrorToConsole false
  debug(cat: string, msg: string, data?: unknown): void;
  info(cat: string, msg: string, data?: unknown): void;
  warn(cat: string, msg: string, data?: unknown): void;
  error(cat: string, msg: string, data?: unknown): void;
  subscribe(cb: (e: LogEntry) => void): () => void;  // fires on each new append; returns an unsubscribe fn
  snapshot(): LogEntry[];                             // current buffer, oldest-first
  clear(): void;                                      // empties the buffer (no subscriber notification)
  setMirrorToConsole(on: boolean): void;
}

export const log: Logger;   // the app-wide singleton (capacity 1000, console mirror off)
```

Behavior:
- Each `debug/info/warn/error` builds a `LogEntry` (stamping `seq` from an internal counter and `t = Date.now()`), pushes it into a ring buffer capped at `capacity` (oldest evicted when full), and synchronously notifies every subscriber with the new entry.
- `mirrorToConsole` (default **off**) additionally forwards to `console[level]` — kept off by default so the test suite's output stays pristine; the Log tab exposes a toggle.
- `subscribe` fires only on new appends and returns an unsubscribe function; a subscriber added after entries exist calls `snapshot()` once to backfill (the panel does this on mount).
- `clear()` empties the buffer and does **not** notify subscribers. The Log panel owns the Clear button: it calls `log.clear()` then re-renders empty from `snapshot()`. This keeps the subscriber contract to a single append event — no separate clear/reset channel is needed.

### Restore decoupling — orchestrator seam (`app/ui/restore-orchestrator.ts` + `restore-panel.ts`)

The bug lives in DOM glue, so to make the fix regression-testable it is extracted into a DOM-light **`RestoreOrchestrator`** that depends only on an injected IO seam (real DOM in the browser, stubs in tests). `restore-panel.ts` becomes the thin adapter that builds the real IO and runs the scan-step loop.

**`RestoreOrchestrator` (`app/ui/restore-orchestrator.ts`)**

```ts
export interface RestoreIO {
  container: HTMLElement;                          // the #archives list element (real or a DOM stub)
  files: { saveRestored(e: Omit<StoredFile, 'createdAt'>): Promise<void> };
  promptPassword(message: string): string | null;  // wraps window.prompt (null = cancelled)
  download(data: Uint8Array, name: string): void;   // wraps the Blob/anchor download
  fallbackName(): string;                           // e.g. the #fname value or 'restored.bin'
  setFileName(name: string): void;                  // reflect a recovered filename back into the UI
  setStatus(msg: string): void;
  log: Logger;
}

export class RestoreOrchestrator {
  constructor(io: RestoreIO);
  startSession(transport: Transport): void;   // new RestoreController(transport); clear container via renderArchiveList(container, [], onPick)
  scanStep(signal: AbortSignal): Promise<void>;// ONE scanNextCard(signal) + renderArchiveList(container, list, onPick=restoreArchive) + detection log; throws AbortError/TagTimeoutError/… to the caller
  restoreArchive(id: string): Promise<void>;   // standalone restore, the onPick handler; callable anytime
}
```

- `restoreArchive(id)`: returns early (with a log line) if there is no active controller or `restoring` is already true (a private guard that prevents overlapping restores / double password prompts); otherwise sets `restoring = true`, logs `restore` "clicked" `{id}`, runs the password-retry loop (`ctrl.restore(id, pw)`; on `PasswordRequiredError`/`DecryptionError` → `io.promptPassword(message)` → retry, max 5; a `null` prompt cancels), calls `io.download(data, name)` and `io.setFileName` on a recovered name, then the non-fatal Files capture (`io.files.saveRestored({ … payload: ctrl.assembledPayload(id) })`), logging start/success/error/download/capture, and clears `restoring` in `finally`.
- `scanStep(signal)`: one `ctrl.scanNextCard(signal)` then `renderArchiveList(io.container, list, (id) => this.restoreArchive(id))` and a detection log. It does not swallow errors — the panel's loop routes them.

**`restore-panel.ts` (thin adapter)**

- Builds a `RestoreIO` from the real DOM (`#archives` container, `#restore-status`, `#fname`), `filesController`, a `promptPassword` over `window.prompt` with the encrypted/wrong-password messages, a `download` over Blob+anchor, and the `log` singleton; constructs one `RestoreOrchestrator`.
- **Scan** click: `orch.startSession(currentTransport())`; create `scanAbort`; loop `for(;;){ try { await orch.scanStep(scanAbort.signal) } catch (e) { AbortError → break; TagTimeoutError → continue; UnsupportedTagError → status+continue; else → status+continue } }`; `finally` re-enables Scan / disables Stop and logs scan stopped.
- **Stop** click: `scanAbort?.abort()` — stops accumulating; the orchestrator, its controller, and the rendered archives (with working Restore buttons) persist.

Result: restore archive A, then B, then C from one scan, and restore after Stop, all work — each button calls `orch.restoreArchive` directly against the still-live controller, independent of scan-loop state. `startSession` clears the container so a new scan drops stale rows.

Concurrency: a restore may overlap a running scan safely — `RestoreController.restore`/`assembledPayload` snapshot the group's chunks (`[...group.chunks.values()]`) at call time, and the transport is used only by the scan loop (restore is in-memory compute). The `restoring` guard serializes user-triggered restores.

### Log tab UI (`app/ui/log-panel.ts` + `index.html` + `shell.ts`)

- `shell.ts`: add `'log'` to the `TABS` tuple (`['archive','restore','files','log','about']` — order per the Global Constraints below). The existing tab machinery (per-tab button click → `activateTab`) then covers it.
- `index.html`: add a `<button role="tab" data-tab="log">Log</button>` in `#tabs` and a `<section id="panel-log">` containing a controls row (`#log-clear`, `#log-copy`, `#log-download`, a `#log-level` `<select>` with debug/info/warn/error, a `#log-console` mirror-to-console checkbox, a `#log-autoscroll` checkbox) and a scrolling monospace container `#log`.
- `log-panel.ts` `initLogPanel()`:
  - Backfills from `log.snapshot()`, then `log.subscribe` to append each new entry as a row. Rows are non-interactive text (`hh:mm:ss.mmm  LEVEL  [cat]  msg  {data-json}`), so simple append is safe (no reconcile needed); a row below the current `#log-level` threshold is created hidden and toggled when the filter changes.
  - **Clear** → `log.clear()` then re-render empty. **Copy** → join visible entries to text → `navigator.clipboard.writeText`. **Download** → Blob `.txt` (`nfc-archiver-log-<timestamp>.txt`). **Level filter** → show/hide rows at/above the selected minimum level. **Mirror to console** → `log.setMirrorToConsole`. **Auto-scroll** (default on) → scroll to bottom on new entries.
- `main.ts`: call `initLogPanel()` alongside the other panel inits.

### Instrumentation points (UI/glue layer)

- `device.ts`: `device` "connecting" / "connected" `{name?}` / "connect failed" `{error}` / "disconnected".
- `restore-panel.ts`: `scan` started / stopped; `scan` detection `{count, complete}` per render; per-tap `warn` skip/timeout/unsupported; `restore` clicked `{id}` / password-prompt / success `{bytes, name}` / error `{error}` / download `{name}` / files-capture ok|fail.
- `archive-panel.ts` (light): `archive` prepared `{cards}` / write progress `{written, total}` / complete.
- `files-panel.ts` (light): `files` download `{id}` / delete `{id}` / clear `{count}`.

Log `data` payloads carry only small, non-sensitive context (ids, counts, sizes, error messages) — never file contents or passwords.

## Data flow

Module calls `log.info(cat, msg, data)` → `Logger` appends to the ring buffer + notifies subscribers → the Log panel (if mounted) appends a row. Export copies/downloads the current buffer as text. Reload clears everything.

## Error handling

- The logger never throws into callers: `subscribe` callbacks are invoked in a try/catch so a broken subscriber can't break logging; a failed `console` mirror is ignored.
- Instrumentation calls are fire-and-forget (`log.*` returns void) and must never change control flow — a logging call is never in a position where its absence would alter behavior.
- The restore refactor preserves all existing error handling (password retry, non-fatal Files capture, per-tap skips); it only relocates where restore is invoked from.

## Testing

- **`src/log/logger.ts`** unit tests (under `node --test`): append then `snapshot()` returns entries oldest-first with monotonic `seq`; ring-buffer eviction at capacity (e.g. capacity 3, push 5 → last 3 kept); `subscribe` fires on each append and the returned unsubscribe stops further calls; `clear()` empties the buffer; `setMirrorToConsole(true)` forwards to `console` (spy) and the default is silent; a throwing subscriber does not break `log.*` or other subscribers.

- **`app/ui/restore-orchestrator.ts`** — a DOM-stub regression test (`test/restore-orchestrator.test.ts`) that reproduces the exact bug and proves the fix. It reuses the minimal `makeDoc()` DOM stub from `test/restore-view.test.ts` (same shape: `createElement`, `children`, `append/appendChild/remove`, `get/setAttribute`, `addEventListener`, `click`) for the `container`, and a `MockTransport` for detection:
  - Build the orchestrator with a stub `RestoreIO`: the stub `container`; a `download` capturing `{data, name}` calls; a `promptPassword` returning a scripted password; a `files` whose `saveRestored` records entries; capturing `setStatus`/`setFileName`/`fallbackName`; a fresh `Logger`.
  - `startSession(mock)`, enqueue a **plain** archive A and an **encrypted** archive B (built with an `archiveToCards`-style helper), then call `scanStep(new AbortController().signal)` repeatedly until both are complete — driving detection deterministically without touching the infinite panel loop (`MockTransport.awaitTag` throws `TagTimeoutError` when idle, so the test never runs an unbounded loop).
  - Find A's Restore button in the stub container (`[data-archive-id]` row → button child), `.click()` it, await, and assert `download` fired with A's original bytes + filename and a Files entry was saved. Then click **B**'s button (encrypted → `promptPassword` supplies the password) and assert the decrypted original bytes. Then click **A's button again** and assert it restores a **second** time — this is the regression assertion: the pre-fix one-shot handler restored only once, so a re-click doing nothing (no new `download` call) would fail this test.
  - A `scanStep`-free assertion: after detection, call `restoreArchive(id)` directly (simulating "restore after Stop") and confirm it still downloads — proving restore does not depend on an active scan loop.

- **`log-panel.ts`** and the thin `restore-panel.ts` adapter remain DOM glue; the reusable renderer's click reliability is covered by `test/restore-view.test.ts`, the orchestration by the test above, and the live Log-tab trace is the manual acceptance evidence. No further DOM harness is added for the thin adapter (YAGNI).

## Out of scope (YAGNI)

- Cross-reload / persistent log storage; remote log shipping.
- Instrumenting the dependency-free core codecs or the transport/SDK layer (can be added later since the logger lives in `src/`).
- Log search, structured filtering beyond a min-level threshold, or per-category toggles.
- Changing restore UX beyond the decoupling (e.g. auto-stopping the scan on pick) — scanning keeps running until Stop.

## Global constraints

- Core (`src/`) stays dependency-free and uses only web-platform globals; the logger adds no runtime dependency (`dependencies` stays exactly `['chameleon-ultra.js']`).
- ESM NodeNext: intra-project imports use `.js` paths.
- Tab order in `shell.ts` `TABS` and in `index.html`: `archive, restore, files, log, about` (Log before About).
- Console mirroring defaults **off** so `npm test` output stays pristine.
- Log `data` never contains file contents or passwords.
- Reuse the existing in-place reconcile renderer (`renderArchiveList`) and typed errors (`PasswordRequiredError`, `DecryptionError`); do not reintroduce `innerHTML=''` list rebuilds in the restore flow.
- Node ≥ 22 for tests/build; `rm -rf dist` before `npm test`.
