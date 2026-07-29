# Resilient webapp archive write flow

**Date:** 2026-07-29
**Scope:** `webapp/` (Chameleon Ultra browser app) only. The Flutter app is out of scope.

## Problem

When writing an archive across many cards (e.g. 12 NTAG chips), a single bad
event aborts the entire session and discards all progress — the user must
re-prepare and re-tap from card 1. The two triggers reported:

- **Wrong-format / unusable card** presented mid-session.
- **Misplaced card** — pulled off the reader before the write-and-verify
  completes.

### Root cause

`webapp/app/ui/archive-panel.ts` runs a `while (!done)` loop. It already
survives three cases by looping back to "tap the next card":

- `TagTimeoutError` (no card detected) → `continue`
- `UnsupportedTagError` (wrong tag type) → `continue`
- `OverwriteRequiredError` (card already holds NFAR data) → confirm → overwrite/skip

But **any other thrown error** — `WriteVerifyError`, `CardAuthError`, a card
yanked mid-write (I/O failure), a decode glitch, or a Bluetooth disconnect —
falls through to the outer `catch`, which calls `hideProgress()` and ends the
session. All previously written cards' progress is lost.

Separately, **BLE disconnects are never detected**: `onConnectionChange`
listeners only ever receive `true` (on connect). Nothing fires `false`, even
though the SDK's `ChameleonUltra.emitter` emits a `'disconnected'` event and
`isConnected()` is available.

## Requirements (confirmed with user)

1. **Target:** webapp only.
2. **On a per-card failure:** retry only. Stay on the same chunk, prompt a
   re-tap. The session must never abort from an error; the only way the loop
   ends is all chunks written. (No "skip" and no error-triggered "stop".)
3. **On reader disconnect mid-session:** pause and resume. Reconnecting
   continues the *same* session from the next unwritten card — nothing
   re-prepared, nothing re-tapped.

## Approach

**Extract an `ArchiveOrchestrator`** (approach A, chosen). Move the write loop
out of the `archive-panel.ts` click handler into a DOM-free class behind an
injected IO seam, mirroring the existing `RestoreOrchestrator` /
`restore-orchestrator.test.ts` pattern. This is the only approach that makes
the new retry/pause logic unit-testable, and it matches the pattern the
codebase adopted in the Log-tab iteration.

Rejected:
- **B — patch the loop inline in `archive-panel.ts`:** smaller diff, but the
  resilience logic (most likely to regress) stays untestable inside a click
  handler — exactly what the restore refactor existed to avoid.
- **C — push resilience into `ArchiveController`:** wrong layer. The controller
  is the transactional "write one card" unit; retry/pause/reconnect is a
  loop-and-UI concern.

## Design

### Component 1 — Connection truth + disconnect signal (`device.ts`)

- Track internal `connected: boolean`.
- On successful connect: `connected = true`, fire `cb(true)` (unchanged).
- Wire `ultra.emitter.on('disconnected', …)`: set `connected = false`, null the
  shared `transport`, update the device bar text, and notify listeners
  `cb(false)`.
- Export `isConnected(): boolean`.

This is the missing sensor for pause/resume, and correct behavior on its own.

**Dependency fence:** all `chameleon-ultra.js` / `emitter` access stays inside
`device.ts` (already one of the two files allowed to import the SDK). The
orchestrator never touches the SDK.

### Component 2 — Reconnect-friendly controller (`controller.ts`)

Add one method to `ArchiveController`:

```ts
setTransport(t: Transport): void
```

The controller retains all session state (`chunks`, `written`, `writtenUids`,
`payloadSize`); only the transport reference is swapped in on reconnect. The
constructor and `writeNextCard(signal?, confirmOverwrite?)` signature are
unchanged, so all 7 existing `controller.test.ts` call-sites keep compiling.

### Component 3 — `ArchiveOrchestrator` (new `app/ui/archive-orchestrator.ts`)

Owns the loop behind an `ArchiveIO` seam:

```ts
export interface ArchiveIO {
  setStatus(msg: string): void;
  showProgress(label: string, value: number | null, max: number): void;
  hideProgress(): void;
  confirmOverwrite(): boolean;      // wraps window.confirm in the panel
  isConnected(): boolean;
  awaitReconnect(): Promise<Transport>; // resolves with the fresh transport
  log: Logger;
}
```

Loop contract: **the loop exits only on `done` (all chunks written) — never on
an error.**

At the top of each iteration and after any throw, check `io.isConnected()`:

- **Disconnected** → `setStatus("Reader disconnected — reconnect to resume")`,
  `const t = await io.awaitReconnect()`, `ctrl.setTransport(t)`, `continue`
  from the same chunk.

Otherwise dispatch on the error from `writeNextCard`:

- `TagTimeoutError` → status hint ("tap a card…"), `continue`.
- `UnsupportedTagError` → status hint ("unsupported tag…"), `continue`.
- `OverwriteRequiredError` → `io.confirmOverwrite()`: if yes, retry with
  `confirmOverwrite = true`; if no, status "Skipped. Tap a different card…",
  `continue`.
- **Any other error** (`WriteVerifyError`, `CardAuthError`, mid-write I/O,
  decode) → `log.warn(...)`, `setStatus("Card N didn't take — <reason>. Re-tap
  to retry.")`, `continue`. **This replaces the removed outer `catch` that
  aborted the session.**

On success: update progress via `io.showProgress` / `io.setStatus`, surface any
`rechunkedTo` note (unchanged from current behavior), set `done`.

### Component 4 — `archive-panel.ts` (thin)

Gather source + options, `prepare`, construct an `ArchiveOrchestrator` with real
IO, run it. `awaitReconnect` is implemented via `onConnectionChange`: register a
one-shot listener that resolves with `currentTransport()` on the next `true`.
`confirmOverwrite` wraps `window.confirm`. The `showProgress` / `hideProgress` /
`setStatus` DOM helpers move into the IO implementation.

## Data flow

**Happy path:** prepare → loop { awaitTag → (first card: maybe rechunk) →
peekIsNfar guard → writeChunk (write+verify) → mark written → render } → done.

**Bad card:** writeNextCard throws (verify/auth/I-O) → still connected → log +
status "re-tap to retry" → `written` unchanged, card not in `writtenUids` →
next tap retries the same chunk index (overwriting a partial write).

**Disconnect at card k:** writeNextCard throws or loop-top check sees
`!isConnected()` → status "reconnect to resume" → `await awaitReconnect()` →
user clicks Connect → new AutoTransport built in `device.ts` → listener resolves
→ `ctrl.setTransport(newTransport)` → loop continues at card k. Prepared chunks
and `written`/`writtenUids` are intact; no re-prepare, no re-tap of done cards.

## Edge cases

- **Partial-write then verify-fail:** re-tapping the same card may trip
  `OverwriteRequiredError` (partial NFAR now present) → user confirms overwrite
  → completes. Acceptable.
- **`CardAuthError` on a non-factory Classic card:** that specific card can
  never succeed; retry-only naturally covers it — the user taps a different
  card (same UX as `UnsupportedTagError`).
- **First-card auto-rechunk on repeated retries:** `rechunkForCapacity` is
  idempotent for a given payload size (assemble → re-split), so re-tapping a
  failing first card re-runs it harmlessly.

## Testing (`test/archive-orchestrator.test.ts`)

Mirror `restore-orchestrator.test.ts` — DOM/IO stub + `MockTransport`:

1. **Bad card doesn't abort:** a `MockTransport` that throws
   `WriteVerifyError` once mid-session, then succeeds on re-tap → the loop
   completes all chunks; progress is never hidden.
2. **Disconnect pauses and resumes:** IO reports `isConnected() === false`
   after card k and `awaitReconnect()` resolves with a fresh `MockTransport`
   pre-loaded to continue → the loop resumes at card k and finishes; the
   assembled cards restore byte-identically.
3. **Controller `setTransport`:** swapping the transport mid-session on the
   controller preserves `written` / `writtenUids` and writes the correct next
   chunk.

Full suite (`rm -rf dist && npm test`, Node ≥ 22 via `nvm use --lts`) stays
green.

## Out of scope

- Any change to the Flutter app.
- "Skip this card" and error-triggered "stop" (explicitly declined).
- Localization of the new strings (webapp has no l10n yet).
