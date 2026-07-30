# Card inspector: raw card dump + decoded NFAR header

**Date:** 2026-07-30
**Scope:** `webapp/` only — repurposes the device-bar "Diagnose card" button into an
"Inspect card" overlay. No change to the NFAR format, the transports, or the
archive/restore flows. The Flutter app is out of scope.

## Problem

Diagnosing a suspect card currently means leaving the app. When a Mifare card
written by the web app failed to restore (fixed in PR #42), the decisive evidence
came from dumping the card in the **ChameleonUltra phone GUI**, screenshotting
it, and decoding the 28-byte NFAR header by hand — byte offsets, big-endian
fields, the CRC32 tail. That worked, but it needed a second device, a second app,
and manual byte arithmetic that the web app is already capable of doing itself.

Everything required is present. `ChameleonDevice` exposes `readBlock` for Mifare
Classic and `transceive14a` for NTAG pages; `AutoTransport` already learns the
medium from the SAK; `chunk.ts` knows the header layout and `crc32.ts` can verify
the tail. Only the presentation is missing.

Meanwhile the existing button under-delivers. It runs a genuinely valuable manual
anticollision — 7-bit WUPA then CL1, deliberately **bypassing the reader
firmware's BCC check** so a malformed-block-0 "magic" card can be identified even
when the firmware rejects it outright with `HF tag uid bcc error` — but reports
only ATQA, UID and BCC into a one-line status area.

## Decisions (confirmed with user)

1. **One button**, relabelled `Inspect card`. The BCC diagnostic is **folded into
   the overlay's identity header**, not dropped — it is the app's only way to
   identify a malformed magic card.
2. **Raw dump plus a decoded NFAR header panel**, including CRC verification. No
   payload preview or filename unwrapping (deliberately out of scope).
3. **Full dump of both media**, rendered **progressively** as bytes arrive.
4. **Per-sector auth failures do not abort** the dump.
5. **Copy/Download produce a plain-text report** of the whole overlay.
6. **The button is disabled while the reader is busy** with an archive write or an
   active scan.

## Architecture

Following the established split — dependency-free logic in `src/`, DOM in
`app/ui/`:

```
device-bar "Inspect card" click
        │
        ├─ diagnostics.ts  diagnoseCard()          ← existing, unchanged
        │     └→ identity: ATQA, UID CL1, BCC returned/computed, verdict
        │
        └─ app/ui/inspect-dialog.ts  openInspector(device)
              opens <dialog> immediately, then:
              │
              ├─ src/inspect/card-dump.ts   dumpCard(device, onUnit)
              │     routes by SAK · emits each block/page as it is read
              │
              ├─ src/inspect/nfar-describe.ts  describeNfar(bytes)
              │     called once the first 32 data bytes are in
              │
              └─ src/inspect/hex-view.ts    formatUnit(unit)
                    bytes → { label, hex, ascii } rows
```

`Transport` gains nothing. A raw dump is not a chunk operation, so — exactly as
`diagnostics.ts` already does — this talks to the `ChameleonDevice` seam directly
and leaves the archive/restore interface untouched.

## Components

| File | Responsibility | Depends on |
|---|---|---|
| `src/inspect/card-dump.ts` | Route by SAK; read every block (Classic) or page group (NTAG); report each unit via callback; convert a per-sector auth failure into a marked unit rather than a throw. | `ChameleonDevice`, `USABLE_BLOCK_INDEXES`, `detectNtagType` |
| `src/inspect/nfar-describe.ts` | Tolerant decode of the 28-byte header + CRC32 verification. Never throws. | `chunk.ts` constants, `crc32.ts` |
| `src/inspect/hex-view.ts` | Bytes → hex/ASCII rows with sector/page labels, trailer marking. | none |
| `app/ui/inspect-dialog.ts` | The `<dialog>`, progressive rendering, Copy/Download, busy-state gating. | the three above, `diagnostics.ts` |

Three dependency-free modules unit-testable under `node --test`, one DOM module
covered by a DOM stub — mirroring how `restore-orchestrator.ts` and
`restore-view.ts` are already split.

The interface between `card-dump` and `hex-view` is one type, so neither needs to
know which medium produced a unit:

```ts
export interface DumpUnit {
  /** Sector for Classic, page-group start for NTAG; used for the row label. */
  index: number;
  kind: 'data' | 'trailer' | 'manufacturer' | 'cc';
  /** Absent when the read failed. */
  bytes?: Uint8Array;
  /** Set when bytes is absent: 'auth-failed' | 'not-read' | 'short-read'. */
  failure?: 'auth-failed' | 'not-read' | 'short-read';
}
```

### Why `describeNfar` does not reuse `decodeChunk`

`decodeChunk()` throws on the first problem it meets. That is correct for the
restore path, where a bad chunk must not proceed, and useless for an inspector,
where **the failure is the information**. `describeNfar` returns a description
either way:

```ts
export type NfarDescription =
  | { present: false; reason: string }                    // e.g. 'magic mismatch: got 00 00 00 00'
  | {
      present: true;
      version: number;
      flags: number;
      compressed: boolean;
      encrypted: boolean;
      archiveId: string;        // formatted UUID
      chunkIndex: number;
      totalChunks: number;
      payloadSize: number;
      totalLength: number;      // 32 + payloadSize
      crcStored: number | null; // null when the dump has not reached the CRC yet
      crcComputed: number | null;
      crcValid: boolean | null;
      warnings: string[];       // e.g. 'declared length 752 exceeds card capacity'
    };
```

It accepts a **partial** buffer, so the panel can render from the first two data
blocks and fill in CRC status once the dump reaches the tail. `crc32()` is reused
unchanged.

## Reading strategy

**Mifare Classic 1K** — all 64 blocks in index order, each via
`readBlock(n, FACTORY_KEY_A)`. Block 0 and the sector trailers (`n % 4 === 3`)
are included and labelled; the dump is raw, so nothing is skipped. The NFAR
extent is derived from `USABLE_BLOCK_INDEXES` for the header panel, which is why
the panel's byte offsets differ from the raw row order — block 3 sits between
data blocks 2 and 4.

**NTAG213/215/216** — `detectNtagType` via `GET_VERSION`, then `READ` (`0x30`)
from page 0 in steps of 4 pages (each READ returns 16 bytes). Pages 0–3 (UID,
lock bytes, Capability Container) are included and labelled, since the CC is
exactly what PR #41 turned out to hinge on.

Two NTAG-specific quirks the dump must absorb, both at the end of memory:

- A `READ` near the last page **wraps around** to page 0 on real hardware
  (READ always returns 4 pages). The dump therefore requests only whole 4-page
  groups within the type's page count and truncates the final group to the
  real page count, so wrapped bytes are never displayed as if they were the
  tail of memory.
- `FakeChameleon` does not emulate that wrap — it returns a **short** slice
  instead. So the reader must accept a short final response as end-of-memory.
  This is the opposite of `ntag-transport.readMemory`, which rejects a short
  read as `CardReadError`, and the difference is deliberate: mid-memory a short
  read means marginal RF coupling (see PR #42), whereas at the last page it
  means the card has no more pages. `card-dump` therefore tolerates a short
  response **only** on the final group and treats one anywhere else as a failed
  unit.

Each unit is emitted the moment it is read, so the dialog fills top-down.
Progress shows as `reading… n/N`.

**Timing.** Every read is a BLE round trip: ~64 for Classic, ~58 for NTAG216 —
15–25 s with the card held still. Progressive rendering is what makes that
acceptable: identity appears in about a second, the NFAR panel shortly after, and
the user may close the dialog at any point. Closing aborts the remaining reads
via an `AbortSignal`.

## Error handling

| Condition | Behaviour |
|---|---|
| Sector auth fails (`CardAuthError`) | Its 4 blocks render as `── auth failed (non-factory key) ──`; the dump continues to the next sector. |
| Card leaves the field mid-dump | Remaining units render as `not read`; status reads "card left the field — re-tap and inspect again". No nested error dialog. |
| Not an NFAR card | The NFAR panel states why: `not NFAR: magic mismatch (got 00 00 00 00)`. The raw dump is unaffected. |
| `diagnoseCard` itself fails | Identity shows "anticollision failed"; the dump is still attempted, since `readBlock` performs its own select. |
| Unsupported SAK | No dump attempted; identity block explains which media are supported. |

Nothing in this feature writes to a card. Every operation is a read.

## Two corrections carried along

**Medium-aware cascade verdict.** The current text calls a 7-byte UID "not a
4-byte Mifare Classic 1K", phrased as a fault. On an NTAG a 7-byte cascade UID is
simply normal. The identity block treats cascade as a fault only when the SAK
says Classic.

**Reader-busy gating.** Neither `archive-panel.ts` (local `archiving` closure)
nor `restore-panel.ts` (local `scanAbort`) exposes whether it is driving the
reader, so nothing can currently gate on it. `device.ts` gains
`setReaderBusy(busy: boolean)` and keeps the flag beside its connection state;
both panels report into it, and the Inspect button's enabled state becomes
`connected && !readerBusy`. No new module and no import cycle — both panels
already import `device.ts`, which imports neither. This matters because two
callers interleaving BLE commands on one reader could corrupt an in-flight write,
which is the same hazard the `archiving` guard already exists to prevent.

## Testing

- `nfar-describe.test.ts` — a valid chunk; a partial buffer (CRC fields `null`);
  magic mismatch; wrong version; a payload size exceeding card capacity
  (`warnings` populated, `present` still true); CRC mismatch.
- `card-dump.test.ts` against `FakeChameleon` — a full Classic dump emits 64
  units in order; a sector whose key is not factory yields marked units and the
  dump completes; an NTAG213 dump emits the right page count; abort mid-dump
  stops further reads. `FakeChameleon.defineCard` already accepts a custom
  `keyA`, so the auth-failure case needs no new test seam.
- `hex-view.test.ts` — hex/ASCII formatting, non-printable bytes rendered as `.`,
  trailer rows labelled.
- `inspect-dialog.test.ts` — DOM stub: dialog opens before the dump finishes,
  rows append progressively, Copy assembles the full text report.

## Out of scope

- Payload preview and filename unwrapping.
- Editing or writing any card content.
- Binary `.bin` export.
- Mifare key recovery, non-factory key entry, or dictionary attacks.
- Saving dumps to the Files tab.
