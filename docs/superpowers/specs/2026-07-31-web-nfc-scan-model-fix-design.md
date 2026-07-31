# Web NFC scan model: one persistent scan, and loops that cannot starve

**Date:** 2026-07-31
**Scope:** `webapp/` only. Fixes a production defect that hard-freezes the browser, and adds two guards so the same class of failure can never again be undiagnosable. No change to the NFAR format, on-tag bytes, the Chameleon transport, or the Flutter app.

## The defect

Reported from a real device (Pixel 8 Pro, GrapheneOS/Vanadium): connect over phone NFC, press **Scan cards**, and the browser freezes so hard that neither the Stop button nor tab switching responds. Tapping a card produces a vibration but nothing reaches the page.

Diagnosed over wireless ADB. The evidence was decisive:

| Measurement | Value |
|---|---|
| `NfcService: setReaderMode` (page arms a scan) | **1** |
| `onTagRfDiscovered` (OS reads a tag) | **8** |
| Renderer process CPU | **186%** |
| Console output from the app | **0 lines** |

### Root cause

Web NFC's model is **one scan, many `reading` events**. `BrowserNdefIO.awaitReading()` was built as *one call = one scan*:

```ts
this.scanning?.abort();          // kill the live scan
const ac = new AbortController();
this.scanning = ac;
reader.scan({ signal: ac.signal })   // ...and re-arm the SAME reader, same tick
```

So the second card aborts the running scan and immediately calls `scan()` again on the same `NDEFReader` instance, which rejects synchronously inside the renderer. The restore loop catches it and does a bare `continue`, producing an infinite cycle of immediately-rejected promises.

`setReaderMode` appearing exactly once is what proves this: a genuine retry would reach the NFC service each time. It does not, because the rejection never leaves the renderer.

The freeze is **microtask starvation** — awaiting an already-rejected promise yields a microtask but never returns to the event loop's task queue, so nothing renders and no input is handled. And because our own abort turned reader mode off, the eight subsequent taps were discovered by Android and delivered nowhere.

### Two failures, not one

1. **The scan model is wrong** — the direct cause.
2. **The loops can starve the main thread** — what turned a bug into an unrecoverable freeze whose error was unreachable, because both loops log to an in-app buffer that cannot be read while the UI is wedged.

Fixing only (1) would leave the app one fast-rejection away from the same outcome.

## Decisions (confirmed with user)

1. **The persistent scan starts at connect time**, not lazily on first use.
2. **A reading arriving with no waiter is buffered — most recent only, briefly.**
3. Fix both failures; do not ship the scan-model fix alone.

## Architecture

### The invariant

> **`scan()` is called exactly once per `BrowserNdefIO` instance, and the instance is discarded on disconnect.**

This is asserted by tests, not left to convention.

### `BrowserNdefIO` becomes a scan owner

`NdefIO` gains `start(): Promise<void>`.

- **`start()`** creates the `NDEFReader`, installs `onreading`/`onreadingerror` **once**, and calls `scan({signal})` **once**. If `scan()` rejects, `start()` rejects.
- **`awaitReading(opts)`** never calls `scan()`. It consumes a fresh buffered reading if one exists, otherwise registers itself as the single waiter, honouring `signal` and `timeoutMs`.
- **`stop()`** aborts the scan, drops the reader, and clears the waiter and buffer. The instance is then dead; reconnecting constructs a new one.

`onreading` resolves the waiter if there is one, and otherwise buffers.

Only one waiter exists at a time. A second concurrent `awaitReading()` is a programming error and rejects immediately rather than silently replacing the first — the app never does this, and a silent replacement would be the same class of bug being fixed here.

### The reading buffer

A single slot, timestamped, valid for **2000 ms**.

It exists for exactly one case: a tap landing in the few-millisecond gap between one card completing and the loop requesting the next. Without it that tap is silently lost, and across a ten-card pile the user is right to say a tap was ignored.

Anything older than the window is discarded rather than replayed, so a tap made while idle cannot be fed into an operation started later.

### What "connected" means

`WebNfcTransport.connect()` — today an empty method kept only for interface parity — calls `io.start()`. `activateWebNfc()` then `await`s `transport.connect()` exactly as the Chameleon path already does, so both readers connect through the same shape and `device.ts` needs no knowledge of `NdefIO`. Three consequences:

- the NFC permission prompt appears when the user asks for NFC
- the call happens inside a real user gesture, which Web NFC can require
- a refusal or an unsupported browser surfaces at the button, not inside a scan loop

A rejection routes through the existing `failHandOff()`, which already tears down, re-renders, updates the buttons and notifies listeners.

### Starvation guards

**Pacing.** A dependency-free helper in `src/`:

```ts
export function ensureMinInterval(startedAt: number, minMs: number): Promise<void>
```

It awaits the remainder of `minMs` since `startedAt`, or resolves immediately if that has already elapsed. Both loops record an iteration start and call it on **every** error path, with `minMs = 250`. A retry can then never occur more than about four times a second regardless of transport behaviour.

**Circuit breaker.** After **5 consecutive failures with the same error name**, the loop stops, releases the reader, and surfaces the error. The counter resets on any success.

**Waiting is not failing.** The breaker must ignore conditions that mean "the user has not tapped yet", or it would abort a perfectly healthy session. Excluded from the count:

- `TagTimeoutError` — with the Chameleon this fires every 20 s while the user hunts for the next card; five in a row is barely a minute and a half of not tapping, and aborting there would be a worse bug than the one being fixed
- `OverwriteRequiredError` in the archive loop — that is a user prompt, not a failure
- `AbortError` — that is the user pressing Stop

Everything else counts. This converts "spins forever showing nothing" into "stops and says what broke".

**Both guards apply to the archive write loop as well as the restore scan loop.** The archive loop's existing `usable()` check only catches a *swapped* transport; on a fast rejection where the transport is still current it does a bare `continue`. The Chameleon's 300 ms poll and 20 s timeout have been hiding that.

## Testing

- **The regression test for this bug:** `FakeNdefIO` records how many times a scan was armed. A test drives several `awaitReading()` calls across multiple simulated taps and asserts the count is exactly 1. This fails against the current code.
- Buffer behaviour: a reading arriving with no waiter is consumed by the next `awaitReading()`; one older than the window is discarded and the caller waits for a real tap.
- `start()` rejecting propagates to a failed connect rather than a half-connected state.
- A second concurrent `awaitReading()` rejects.
- `ensureMinInterval` resolves immediately when the interval has passed and delays when it has not.
- The circuit breaker: a loop driven with repeated identical failures exits after 5 and surfaces the error, and the counter resets after an intervening success.

## Non-goals

- Any change to `NtagTransport`, `AutoTransport`, the Chameleon path, or on-tag bytes
- Localizing the existing hardcoded strings in `browser-ndef-io.ts`
- Making `device.ts` testable under `node --test` (it imports `chameleon-ultra.js`, which touches `BluetoothUUID` at module scope) — that refactor is real but separate
- Mifare Classic over Web NFC, which remains impossible

## What this still cannot verify

That `scan()` succeeds on real hardware, and that `onreading` fires repeatedly for a single persistent scan across many taps. Both need the device again.

The difference is that a failure now surfaces as a visible message instead of a frozen browser, so the next validation round is a read of the status line rather than a USB cable and a logcat capture.

Separately confirmed during diagnosis: this device does **not** report `com.nxp.mifare`, so PR #50's Mifare Classic support cannot be validated on it at all.
