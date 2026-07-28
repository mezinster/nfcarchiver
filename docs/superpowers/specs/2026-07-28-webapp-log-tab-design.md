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
    log-panel.ts        # subscribes to `log`, renders the Log tab, Clear/Copy/Download/level-filter/auto-scroll
    restore-panel.ts    # MODIFIED: decouple restore from the scan loop + emit log events
    device.ts           # MODIFIED: log connect/disconnect
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

### Restore decoupling (`app/ui/restore-panel.ts`)

Restructure `initRestorePanel` so `RestoreController` and the detected archives outlive the scan loop, and restoring is a standalone action:

- Panel-scoped state: `let ctrl: RestoreController | null`, `let scanAbort: AbortController | null`, `let restoring = false`.
- **`restoreArchive(id: string)`** — standalone async function, the `onPick` handler passed to `renderArchiveList`. It:
  1. returns early (with a log line) if `ctrl` is null or `restoring` is already true (prevents overlapping restores / double password prompts);
  2. sets `restoring = true`, logs `restore` "clicked" `{id}`;
  3. runs the existing password-retry loop (`ctrl.restore(id, pw)` with `PasswordRequiredError`/`DecryptionError` → `prompt` → retry, max 5), triggers the Blob download, then the non-fatal Files-capture (`filesController.saveRestored` with `ctrl.assembledPayload(id)`), logging start/success/error/download/capture;
  4. `finally` sets `restoring = false`.
- **Scan** click: build `ctrl = new RestoreController(transport)`; clear the archives container (`renderArchiveList($('archives'), [], restoreArchive)`); create `scanAbort`; run the accumulate-and-render loop that ends **only** on `AbortError` (Stop) — it never breaks on a pick; per-tap `TagTimeoutError`/`UnsupportedTagError`/other errors continue as today. Each `scanNextCard` return calls `renderArchiveList($('archives'), list, restoreArchive)` and logs the detection summary.
- **Stop** click: `scanAbort?.abort()` — stops accumulating; `ctrl` and the rendered archives (and their working Restore buttons) persist.

Result: restore archive A, then B, then C from one scan, and restore after Stop, all work — because each button calls `restoreArchive` directly against the still-live `ctrl`, independent of scan-loop state. `restoreArchive` reads the outer `ctrl` variable, so it always targets the current scan session; clearing the container at scan start removes stale rows from a prior session.

Concurrency note: while scanning continues, a restore may run concurrently; this is safe because `RestoreController.restore`/`assembledPayload` snapshot the group's chunks (`[...group.chunks.values()]`) at call time, and the transport is used only by the scan loop (restore is in-memory compute). The `restoring` guard serializes user-triggered restores.

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

- `src/log/logger.ts` unit tests (under `node --test`): append then `snapshot()` returns entries oldest-first with monotonic `seq`; ring-buffer eviction at capacity (e.g. capacity 3, push 5 → last 3 kept); `subscribe` fires on each append and the returned unsubscribe stops further calls; `clear()` empties the buffer; `setMirrorToConsole(true)` forwards to console (spy) and default is silent; a throwing subscriber does not break `log.*` or other subscribers.
- `log-panel.ts` and the `restore-panel.ts` refactor are DOM glue. The Restore buttons' click reliability (fire `onPick` per click, across re-renders, per row id) is already covered by `test/restore-view.test.ts`; the multi-restore / restore-after-stop behavior is verified live via the new Log tab trace (the event sequence is the acceptance evidence) and by code review. No new DOM harness is added for the panels (YAGNI — the reusable renderer is already tested, and the fix is a wiring change).

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
