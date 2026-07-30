# Web NFC reader and Disconnect button

**Date:** 2026-07-31
**Scope:** `webapp/` only. Adds a second reader — the phone's own NFC via Web NFC —
selectable alongside the Chameleon Ultra, and a Disconnect button for both. No
change to the NFAR format, the on-tag bytes, the Flutter app, or the deploy
pipeline.

## Problem

The web app can only reach a card through a Chameleon Ultra over Web Bluetooth.
That is a hardware purchase standing between a user and the app's core function,
even though most Android phones already have an NFC radio that can read and write
the NTAG cards this app writes.

Web NFC (`NDEFReader`) closes that gap for the common case. It is also the last
remaining Android-parity item on the web app roadmap besides work already done.

Separately, there is no way to release the Chameleon once connected. `disconnect()`
exists on the `Transport` interface and on the SDK, but nothing in the UI calls
it, so the only way to drop a reader is to reload the page or power the device
off.

## What Web NFC cannot do

These are permanent API limits, not implementation gaps, and they shape the whole
design:

- **NDEF only.** No raw transceive and no sector authentication, so Mifare
  Classic is impossible over Web NFC — forever.
- **No raw page or block access**, so the card inspector cannot work over it.
- **No capability container and no `maxSize`.** There is no way to learn a tag's
  capacity before writing.
- **Chrome on Android only.** Not desktop Chrome, and not iOS in any browser —
  Safari and Chrome-on-iOS both use WebKit, which has no Web NFC.
- **Requires a secure context and a user gesture.** The site is already HTTPS, so
  this costs nothing.

## Decisions (confirmed with user)

1. **Explicit reader picker**, not automatic fallback. The two readers have
   genuinely different capabilities, so the user chooses which is active.
2. **One tap per card normally; a second tap only to confirm an overwrite.** The
   safety prompt survives without asking the user to hold a card against the
   phone while reading a dialog.
3. **Chunk size comes from an explicitly selected tag type.** "Auto-detect" is
   disabled while phone NFC is the active reader, because it cannot work without
   capacity data.
4. **Disconnect is disabled while the reader is busy**, reusing the existing
   `setReaderBusy` interlock rather than inventing a mid-operation abort.

## Architecture

### Device bar

```
[ Connect Chameleon ]  [ Use phone NFC ]   status…   [ Inspect card ]  [ Disconnect ]
```

`Use phone NFC` is rendered only when `'NDEFReader' in window`. On every other
browser it is absent rather than disabled — the same principle applied to hiding
Mifare on incapable phones in the Flutter design.

**Disconnect** is enabled whenever a reader is active and disabled whenever
`readerBusy` is set, which already gates the Inspect button during an archive
write, a scan, or an inspection. It calls `transport.disconnect()`, clears the
shared transport, fires `onConnectionChange(false)`, and returns the bar to idle.
The resilient-write work already treats a dropped reader as pause-and-resume, so
nothing downstream needs to change.

### `WebNfcTransport`

Implements the existing `Transport` interface unchanged: `connect`, `disconnect`,
`awaitTag`, `peekIsNfar`, `readChunk`, `writeChunk`.

It belongs in `src/transport/web-nfc-transport.ts`, not `app/`. `NDEFReader` is a
web-platform global like `crypto.subtle` and `CompressionStream`, both of which
the core already uses; the dependency fence governs the `chameleon-ultra.js`
**package**, not platform globals.

`src/` must run under `node --test`, where `NDEFReader` does not exist, so the
transport depends on a seam rather than the global directly — the same shape as
`ChameleonDevice`:

- `NdefIO` — minimal interface: `scan(signal)`, `write(records)`
- `BrowserNdefIO` — wraps the real `NDEFReader`
- `FakeNdefIO` — test double, alongside `FakeChameleon`

### The one-tap model

- `awaitTag()` starts a scan, resolves on the first `reading` event with the UID
  from `serialNumber`, and **caches the NDEF message that event carried**
- `peekIsNfar()` inspects the cached message — no second tap
- `readChunk()` decodes the chunk from that same cached message, so the restore
  path also costs one tap per card
- `writeChunk()` calls `write()` while the tag is still in the field

A blank card therefore takes one tap. When `peekIsNfar()` is true,
`ArchiveController` raises `OverwriteRequiredError` before `writeChunk` exactly as
it does today; the user answers the dialog and the second tap performs the write.

**Unverified assumption, stated deliberately:** this depends on Chrome's `write()`
targeting the tag currently in range rather than waiting for a fresh tap. It must
be settled on real hardware. If it proves false, the fallback is always-two-taps,
and **the only file that changes is `WebNfcTransport`** — everything above it is
written against `Transport`.

### Capacity

`maxChunkPayload` is derived from the selected tag type rather than from the tag,
because Web NFC exposes no capacity data. The Archive panel disables the
"Auto-detect" option while phone NFC is active and requires an explicit chip.

Sizing reuses `chunkPayloadForCapacity()` so the bytes are identical to the
Chameleon path — an NTAG215 gets 420-byte payloads, matching the terminator
reserve fixed in PR #48/#49.

Note that the platform performs its own TLV framing on this path, so the app's
terminator arithmetic is not in control here. Sizing the payload to 420 keeps the
result comfortably inside the CC-declared area regardless.

A card smaller than the declared type cannot be detected in advance, so the
failure surfaces from `write()` itself — Chrome rejects with a `DOMException`
(`NotSupportedError` or `NetworkError` depending on the failure). `BrowserNdefIO`
maps that rejection to the existing `CardCapacityError`, which `humanError()`
already renders, so the user gets a message naming the mismatch and telling them
to select the correct type rather than a raw DOM error string.

### Degraded capabilities

Both are disabled with an explanatory tooltip rather than failing at point of
use:

- **Inspect card** — no raw page access over Web NFC
- **Mifare Classic** — Web NFC is NDEF-only

Restore works normally: the scan event carries the NDEF message. The Log tab
records which transport served each operation, so a bug report identifies the
reader in play.

## Testing

- **`test/transport-contract.ts` already exists** as a shared suite that
  `NtagTransport` is held to. `WebNfcTransport` joins it against `FakeNdefIO`, so
  it must satisfy the same contract as every other transport. This is the
  highest-value test in the project and it is nearly free.
- **Reader selection and the disconnect interlock** tested through the existing
  IO-seam style — no DOM stub, consistent with `inspect-orchestrator`.
- **The overwrite path** tested explicitly: a cached message that parses as NFAR
  must produce `OverwriteRequiredError` before any write is attempted.
- **Hardware validation on Android Chrome is manual and required**, specifically
  to settle the one-tap assumption in §The one-tap model.

## Non-goals

- Mifare Classic over Web NFC — impossible, the API is NDEF-only
- The card inspector over Web NFC — no raw access
- iOS or desktop support — Web NFC exists on neither
- Auto-detect tag type over Web NFC — no capacity data to detect from
- A mid-operation abort for Disconnect (decision 4)
- Any change to the NFAR format, on-tag bytes, the Flutter app, or the deploy
  pipeline
