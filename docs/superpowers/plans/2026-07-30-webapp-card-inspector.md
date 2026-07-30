# Card inspector — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the device-bar "Diagnose card" button into "Inspect card" — a modal showing card identity, a decoded NFAR chunk header with CRC verification, and a raw hex/ASCII dump that fills in progressively as the reads arrive.

**Architecture:** Three dependency-free modules under `src/inspect/` (tolerant NFAR description, raw dump over the `ChameleonDevice` seam, text rendering) plus a DOM-free orchestrator and a thin DOM panel in `app/ui/`. `Transport` is untouched: a raw dump is not a chunk operation, so like the existing `diagnostics.ts` this talks to `ChameleonDevice` directly. Nothing in this feature writes to a card.

**Tech Stack:** TypeScript, `node --test`, native `<dialog>`, esbuild. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-30-webapp-card-inspector-design.md`

## Global Constraints

- **Node ≥ 22 required.** Run `source ~/.nvm/nvm.sh && nvm use --lts` first — the shell default is Node 14.
- **Always `rm -rf dist && npm test`.** The `tsc && node --test` chain does not clean stale compiled tests.
- **All webapp commands run from `webapp/`.** Never the repo root.
- **No new dependencies**, runtime or dev.
- **Dependency fence:** `chameleon-ultra.js` may be imported ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`. Everything in `src/inspect/` and `app/ui/inspect-orchestrator.ts` must stay SDK-free.
- **Read-only:** no step in this plan may call `writeBlock` or issue an NTAG `WRITE` (`0xA2`).
- **Branch:** `feat/webapp-card-inspector` (exists; spec commit `ad247dc` is its first commit).
- **Baseline:** master is at 164 tests passing. Each task's test count is stated as a delta.
- **Sequencing note:** PR #45 also edits `webapp/README.md`. If it has landed, `git pull` master into this branch before Task 5; if not, expect a trivial conflict on the Features list and keep both bullets.

## File Structure

| File | Responsibility |
|---|---|
| `src/inspect/nfar-describe.ts` | Tolerant decode of the 28-byte NFAR header + CRC verification. Never throws; accepts a partial buffer. |
| `src/inspect/card-dump.ts` | Route by SAK, read every block/page group, emit each as a `DumpUnit`. Owns the `DumpUnit` type. |
| `src/inspect/hex-view.ts` | Render a `DumpUnit` as a hex/ASCII row, and assemble the full plain-text report. |
| `src/nfc/type2.ts` | *(modify)* gains `ntagTotalPages()` — total pages per NTAG type, needed for a raw dump. |
| `app/ui/inspect-orchestrator.ts` | DOM-free: run diagnose → dump → describe, pushing output through an injected `InspectIO`. |
| `app/ui/inspect-panel.ts` | The `<dialog>`: wires DOM to `InspectIO`, Copy/Download, abort-on-close. |
| `app/ui/device.ts` | *(modify)* button rename + `setReaderBusy()`. |
| `app/index.html` | *(modify)* button label/id + dialog markup. |

Splitting the modal into orchestrator + panel mirrors `restore-orchestrator.ts` / `restore-panel.ts`. It also means the progressive-rendering behaviour is testable with a plain stub object — no DOM stub needed anywhere in this plan.

---

### Task 1: Tolerant NFAR header description

**Files:**
- Create: `webapp/src/inspect/nfar-describe.ts`
- Test: `webapp/test/nfar-describe.test.ts`

**Interfaces:**
- Consumes: nothing new. Reuses `NFAR_MAGIC`, `NFAR_VERSION`, `HEADER_SIZE`, `TOTAL_OVERHEAD`, `FLAG_COMPRESSED`, `FLAG_ENCRYPTED` from `src/chunk.js`; `crc32` from `src/crc32.js`; `formatArchiveId` from `src/archive-id.js`; `CARD_CAPACITY_BYTES` from `src/mifare/card-layout.js`.
- Produces: `describeNfar(data: Uint8Array): NfarDescription`, and the exported types `NfarDescription`, `NfarPresent`, `NfarAbsent`.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/nfar-describe.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeNfar } from '../src/inspect/nfar-describe.js';
import { encodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, HEADER_SIZE } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

const ID = new Uint8Array([
  0x96, 0xd4, 0x5d, 0x14, 0xa5, 0xc1, 0x43, 0x56,
  0x8f, 0x05, 0x01, 0xf2, 0x83, 0x0d, 0x77, 0xf9,
]);

function chunkBytes(payload: Uint8Array, flags = 0, chunkIndex = 0, totalChunks = 1): Uint8Array {
  return encodeChunk({ archiveId: ID, totalChunks, chunkIndex, payload, crc32: crc32(payload), flags });
}

test('describes a valid chunk, CRC verified', () => {
  const payload = new TextEncoder().encode('Test');
  const d = describeNfar(chunkBytes(payload, FLAG_COMPRESSED | FLAG_ENCRYPTED));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.version, 1);
  assert.equal(d.archiveId, '96d45d14-a5c1-4356-8f05-01f2830d77f9');
  assert.equal(d.compressed, true);
  assert.equal(d.encrypted, true);
  assert.equal(d.chunkIndex, 0);
  assert.equal(d.totalChunks, 1);
  assert.equal(d.payloadSize, 4);
  assert.equal(d.totalLength, 36);
  assert.equal(d.crcValid, true);
  assert.deepEqual(d.warnings, []);
});

test('a partial buffer describes the header with CRC status unknown', () => {
  // Only the 28-byte header has been read so far — the CRC tail has not arrived.
  const full = chunkBytes(new TextEncoder().encode('Test'));
  const d = describeNfar(full.subarray(0, HEADER_SIZE));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.payloadSize, 4);
  assert.equal(d.crcStored, null);
  assert.equal(d.crcComputed, null);
  assert.equal(d.crcValid, null, 'unknown must be null, never false — false would read as corruption');
});

test('a blank card reports a magic mismatch, not an exception', () => {
  const d = describeNfar(new Uint8Array(32));
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /magic mismatch/);
  assert.match(d.reason, /4E 46 41 52/);
});

test('an unsupported version is reported by number', () => {
  const bytes = chunkBytes(new Uint8Array([1, 2, 3]));
  bytes[4] = 9;
  const d = describeNfar(bytes);
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /version 9/);
});

test('too few bytes to judge is reported as such', () => {
  const d = describeNfar(new Uint8Array([0x4e, 0x46]));
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /only 2 bytes/);
});

test('a payload size larger than the card warns but still describes', () => {
  const bytes = chunkBytes(new Uint8Array([1, 2, 3]));
  new DataView(bytes.buffer).setUint16(26, 4000); // absurd payload size
  const d = describeNfar(bytes);
  assert.equal(d.present, true, 'a bad length must not hide the rest of the header');
  if (!d.present) return;
  assert.equal(d.payloadSize, 4000);
  assert.ok(d.warnings.some((w) => /exceeds/.test(w)), JSON.stringify(d.warnings));
  assert.equal(d.crcValid, null, 'the declared tail is past the buffer, so CRC is unknown');
});

test('a corrupted payload reports crcValid false', () => {
  const bytes = chunkBytes(new TextEncoder().encode('Test'));
  bytes[HEADER_SIZE] ^= 0xff; // flip a payload byte, leave the stored CRC alone
  const d = describeNfar(bytes);
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.crcValid, false);
  assert.notEqual(d.crcStored, d.crcComputed);
});

test('unknown flag bits are warned about', () => {
  const d = describeNfar(chunkBytes(new Uint8Array([1]), 0x80));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.ok(d.warnings.some((w) => /unknown flag/.test(w)), JSON.stringify(d.warnings));
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npx tsc 2>&1 | head -3
```

Expected: FAIL — `Cannot find module '../src/inspect/nfar-describe.js'`.

- [ ] **Step 3: Write the implementation**

Create `webapp/src/inspect/nfar-describe.ts`:

```ts
/**
 * Tolerant NFAR header description for the card inspector.
 *
 * `decodeChunk()` throws on the first problem it meets. That is correct for the
 * restore path, where a bad chunk must not proceed, and useless here: in an
 * inspector the failure IS the information ("magic mismatch: got 00 00 00 00").
 * This reports instead of raising.
 *
 * It also accepts a PARTIAL buffer, so the dialog can render the header from the
 * first two data blocks and fill in CRC status later, once the dump reaches the
 * tail. Unknown CRC status is `null`, never `false` — `false` would read as
 * corruption.
 */
import {
  NFAR_MAGIC, NFAR_VERSION, HEADER_SIZE, TOTAL_OVERHEAD,
  FLAG_COMPRESSED, FLAG_ENCRYPTED,
} from '../chunk.js';
import { crc32 } from '../crc32.js';
import { formatArchiveId } from '../archive-id.js';
import { CARD_CAPACITY_BYTES } from '../mifare/card-layout.js';

export interface NfarAbsent {
  present: false;
  reason: string;
}

export interface NfarPresent {
  present: true;
  version: number;
  flags: number;
  compressed: boolean;
  encrypted: boolean;
  archiveId: string;
  chunkIndex: number;
  totalChunks: number;
  payloadSize: number;
  /** 32 + payloadSize — the whole chunk's on-card length. */
  totalLength: number;
  /** null until the dump has read as far as the CRC tail. */
  crcStored: number | null;
  crcComputed: number | null;
  crcValid: boolean | null;
  /** Non-fatal oddities worth surfacing; the header is still described. */
  warnings: string[];
}

export type NfarDescription = NfarAbsent | NfarPresent;

const spaced = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

export function describeNfar(data: Uint8Array): NfarDescription {
  const minToJudge = NFAR_MAGIC.length + 1;
  if (data.length < minToJudge) {
    return { present: false, reason: `only ${data.length} bytes read; need at least ${minToJudge} to identify a chunk` };
  }
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (data[i] !== NFAR_MAGIC[i]) {
      return {
        present: false,
        reason: `magic mismatch: got ${spaced(data.subarray(0, NFAR_MAGIC.length))}, expected 4E 46 41 52 ("NFAR")`,
      };
    }
  }
  const version = data[4]!;
  if (version !== NFAR_VERSION) {
    return { present: false, reason: `unsupported version ${version} (expected ${NFAR_VERSION})` };
  }
  if (data.length < HEADER_SIZE) {
    return { present: false, reason: `header incomplete: ${data.length} of ${HEADER_SIZE} bytes read` };
  }

  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const flags = data[5]!;
  const totalChunks = view.getUint16(22);
  const chunkIndex = view.getUint16(24);
  const payloadSize = view.getUint16(26);
  const totalLength = TOTAL_OVERHEAD + payloadSize;

  const warnings: string[] = [];
  if (totalLength > CARD_CAPACITY_BYTES) {
    warnings.push(`declared length ${totalLength} B exceeds Mifare Classic 1K capacity ${CARD_CAPACITY_BYTES} B`);
  }
  if ((flags & ~(FLAG_COMPRESSED | FLAG_ENCRYPTED)) !== 0) {
    warnings.push(`unknown flag bits set: 0x${flags.toString(16).padStart(2, '0')}`);
  }
  if (totalChunks > 0 && chunkIndex >= totalChunks) {
    warnings.push(`chunk index ${chunkIndex} is out of range for ${totalChunks} chunk(s)`);
  }

  let crcStored: number | null = null;
  let crcComputed: number | null = null;
  if (data.length >= totalLength) {
    crcStored = view.getUint32(HEADER_SIZE + payloadSize);
    crcComputed = crc32(data.subarray(HEADER_SIZE, HEADER_SIZE + payloadSize));
  }

  return {
    present: true,
    version,
    flags,
    compressed: (flags & FLAG_COMPRESSED) !== 0,
    encrypted: (flags & FLAG_ENCRYPTED) !== 0,
    archiveId: formatArchiveId(data.subarray(6, 22)),
    chunkIndex,
    totalChunks,
    payloadSize,
    totalLength,
    crcStored,
    crcComputed,
    crcValid: crcStored === null ? null : crcStored === crcComputed,
    warnings,
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -6
```

Expected: `tests 172`, `pass 172`, `fail 0` (164 baseline + 8 new).

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/src/inspect/nfar-describe.ts webapp/test/nfar-describe.test.ts
git commit -m "feat(webapp): tolerant NFAR header description for the inspector

decodeChunk() throws on the first problem, which is right for restore and
useless for an inspector, where the failure is the information. describeNfar
reports instead: magic mismatch quotes the bytes it found, a bad payload size
warns but still describes the rest of the header.

Accepts a partial buffer so the dialog can render from the first two blocks and
fill in CRC status when the dump reaches the tail. Unknown CRC status is null,
never false — false would read as corruption."
```

---

### Task 2: Raw card dump

**Files:**
- Create: `webapp/src/inspect/card-dump.ts`
- Modify: `webapp/src/nfc/type2.ts` (add `ntagTotalPages`)
- Test: `webapp/test/card-dump.test.ts`

**Interfaces:**
- Consumes: `ChameleonDevice` + `FACTORY_KEY_A` from `src/transport/chameleon-device.js`; `CardAuthError`, `TagTimeoutError`, `UnsupportedTagError` from `src/transport/transport.js`; `BLOCK_SIZE` from `src/mifare/card-layout.js`; `detectNtagType`, `NtagType` from `src/nfc/type2.js`.
- Produces:
  - `ntagTotalPages(t: NtagType): number` from `src/nfc/type2.js`
  - `dumpCard(dev: ChameleonDevice, cb: DumpCallbacks, signal?: AbortSignal): Promise<DumpResult>`
  - types `DumpCallbacks`, `DumpUnit`, `DumpMeta`, `DumpResult`, `UnitKind`, `UnitFailure`

`DumpCallbacks` carries two callbacks, not one. `onMeta` fires as soon as the
medium is known — after `scanTag` for Classic, after `GET_VERSION` for NTAG —
i.e. **before any block is read**. That is what lets the dialog show the identity
block about a second in, rather than after ~64 BLE round trips. `onUnit` then
fires per unit.

- [ ] **Step 1: Add total page counts to `type2.ts`**

Append to `webapp/src/nfc/type2.ts`, after `ntagUserBytes`:

```ts
/** Total pages per type INCLUDING the config/lock pages, not just user memory.
 *  A raw dump needs all of them; `USER_BYTES` above covers only the NDEF area. */
const TOTAL_PAGES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 45,
  [NtagType.NTAG215]: 135,
  [NtagType.NTAG216]: 231,
};

export function ntagTotalPages(t: NtagType): number {
  return TOTAL_PAGES[t];
}
```

- [ ] **Step 2: Write the failing test**

Create `webapp/test/card-dump.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dumpCard, type DumpMeta, type DumpUnit } from '../src/inspect/card-dump.js';
import { NtagType, ntagTotalPages } from '../src/nfc/type2.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { FakeChameleon } from './fake-chameleon.js';

const CLASSIC_UID = new Uint8Array([0xb9, 0x16, 0x27, 0x51]);
const NTAG_UID = new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]);

/** Collect every unit the dump emits, plus the progress pairs and meta. */
function collector() {
  const units: DumpUnit[] = [];
  const progress: Array<[number, number]> = [];
  const order: string[] = [];
  const cb = {
    onMeta: (m: DumpMeta) => { order.push(`meta:${m.medium}`); },
    onUnit: (u: DumpUnit, done: number, total: number) => {
      units.push(u); progress.push([done, total]); order.push('unit');
    },
  };
  return { units, progress, order, cb };
}

test('Mifare Classic: dumps all 64 blocks, labelling manufacturer and trailers', async () => {
  const device = new FakeChameleon();
  device.place(CLASSIC_UID);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.meta.medium, 'mifare-classic-1k');
  assert.equal(res.meta.sak, 0x08);
  assert.equal(res.units.length, 64);
  assert.equal(c.units.length, 64, 'every unit must also be reported live');
  assert.deepEqual(c.progress[0], [1, 64]);
  assert.deepEqual(c.progress[63], [64, 64]);

  assert.equal(res.units[0]!.kind, 'manufacturer');
  assert.equal(res.units[1]!.kind, 'data');
  assert.equal(res.units[3]!.kind, 'trailer');
  assert.equal(res.units[63]!.kind, 'trailer');
  assert.equal(res.units[4]!.sector, 1);
  assert.ok(res.units.every((u) => u.bytes?.length === 16), 'a factory-keyed card reads clean');
  assert.equal(res.aborted, false);
  assert.equal(res.cardLost, false);
  // onMeta must land before any unit: the dialog shows identity in ~1 s rather
  // than after 64 BLE round trips.
  assert.equal(c.order[0], 'meta:mifare-classic-1k');
  assert.equal(c.order[1], 'unit');
});

test('Mifare Classic: non-factory keys mark units auth-failed without aborting', async () => {
  const device = new FakeChameleon();
  device.defineCard(CLASSIC_UID, { keyA: new Uint8Array([1, 2, 3, 4, 5, 6]) });
  device.place(CLASSIC_UID);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.units.length, 64, 'the dump must run to completion');
  assert.ok(res.units.every((u) => u.failure === 'auth-failed'));
  assert.ok(res.units.every((u) => u.bytes === undefined));
  assert.equal(res.cardLost, false, 'a wrong key is not a lost card');
});

test('Mifare Classic: a non-auth read failure stops early and marks the rest not-read', async () => {
  const fake = new FakeChameleon();
  fake.place(CLASSIC_UID);
  let reads = 0;
  // FakeChameleon signals an empty field as CardAuthError, which is a fake
  // artifact; real hardware surfaces a card leaving the field as something
  // else. Wrap it so the non-auth branch is what gets exercised.
  const device: ChameleonDevice = {
    ...fake,
    isConnected: () => fake.isConnected(),
    connect: () => fake.connect(),
    disconnect: () => fake.disconnect(),
    scanTag: () => fake.scanTag(),
    transceive14a: (d, o) => fake.transceive14a(d, o),
    writeBlock: (b, k, d) => fake.writeBlock(b, k, d),
    readBlock: async (b, k) => {
      reads++;
      if (reads > 10) throw new Error('BLE link lost');
      return fake.readBlock(b, k);
    },
  };
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.units.length, 64, 'the result must still describe the whole card');
  assert.equal(res.cardLost, true);
  assert.ok(res.units.slice(0, 10).every((u) => u.bytes?.length === 16));
  assert.ok(res.units.slice(10).every((u) => u.failure === 'not-read'));
  assert.equal(reads, 11, 'must stop reading, not grind through 53 more failing round trips');
});

test('NTAG213: dumps every page group, truncating the final short group', async () => {
  const device = new FakeChameleon();
  device.placeNtag(NTAG_UID, NtagType.NTAG213);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  const pages = ntagTotalPages(NtagType.NTAG213); // 45
  const groups = Math.ceil(pages / 4);            // 12
  assert.equal(res.meta.medium, NtagType.NTAG213);
  assert.equal(res.units.length, groups);
  assert.equal(res.units[0]!.kind, 'cc', 'group 0 holds UID, lock bytes and the Capability Container');
  assert.equal(res.units[0]!.bytes!.length, 16);
  // 45 pages is not a multiple of 4: the last group is a single page.
  assert.equal(res.units[groups - 1]!.index, 44);
  assert.equal(res.units[groups - 1]!.bytes!.length, 4, 'a short FINAL group is end-of-memory, not a failure');
  assert.equal(res.units[groups - 1]!.failure, undefined);
  // The CC the fake bakes in at page 3.
  assert.deepEqual(Array.from(res.units[0]!.bytes!.subarray(12, 16)), [0xe1, 0x10, 0x12, 0x00]);
});

test('abort stops the dump and reports it', async () => {
  const device = new FakeChameleon();
  device.place(CLASSIC_UID);
  const ac = new AbortController();
  const units: DumpUnit[] = [];
  const res = await dumpCard(device, {
    onUnit: (u) => { units.push(u); if (units.length === 5) ac.abort(); },
  }, ac.signal);

  assert.equal(res.aborted, true);
  assert.ok(units.length >= 5 && units.length < 64, `expected an early stop, got ${units.length}`);
});

test('an unsupported SAK is rejected before any read', async () => {
  const device = new FakeChameleon();
  device.defineCard(CLASSIC_UID, { sak: 0x20 });
  device.place(CLASSIC_UID);
  await assert.rejects(() => dumpCard(device, { onUnit: () => {} }), UnsupportedTagError);
});
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc 2>&1 | head -3
```

Expected: FAIL — `Cannot find module '../src/inspect/card-dump.js'`.

- [ ] **Step 4: Write the implementation**

Create `webapp/src/inspect/card-dump.ts`:

```ts
/**
 * Raw card dump for the inspector. Reads every block (Mifare Classic) or page
 * group (NTAG) and reports each unit the moment it arrives, so the UI can
 * render top-down instead of waiting ~15-25 s for 64 BLE round trips.
 *
 * Talks to the ChameleonDevice seam directly: a raw dump is not a chunk
 * operation, so the Transport interface stays untouched. Read-only throughout.
 *
 * A per-sector auth failure becomes a marked unit rather than a throw — a card
 * with one custom-keyed sector is still mostly readable, and that partial view
 * is itself diagnostic. A NON-auth failure means the card has almost certainly
 * left the field, so the dump stops and marks the remainder rather than grinding
 * through dozens more failing round trips.
 */
import { BLOCK_SIZE } from '../mifare/card-layout.js';
import { detectNtagType, ntagTotalPages, type NtagType } from '../nfc/type2.js';
import { FACTORY_KEY_A, type ChameleonDevice } from '../transport/chameleon-device.js';
import { CardAuthError, TagTimeoutError, UnsupportedTagError } from '../transport/transport.js';

export type UnitKind = 'manufacturer' | 'data' | 'trailer' | 'cc';
export type UnitFailure = 'auth-failed' | 'not-read' | 'short-read';

export interface DumpUnit {
  /** Block number (Classic) or first page of the group (NTAG). */
  index: number;
  /** Sector number for Classic; undefined for NTAG. */
  sector?: number;
  kind: UnitKind;
  /** Absent when the read failed. */
  bytes?: Uint8Array;
  failure?: UnitFailure;
}

export interface DumpMeta {
  medium: 'mifare-classic-1k' | NtagType;
  sak: number;
  uid: Uint8Array;
  totalUnits: number;
}

export interface DumpResult {
  meta: DumpMeta;
  units: DumpUnit[];
  /** The caller aborted (dialog closed). */
  aborted: boolean;
  /** A non-auth read failure stopped the dump — usually the card left the field. */
  cardLost: boolean;
}

const CLASSIC_BLOCKS = 64;
const PAGES_PER_READ = 4;

export interface DumpCallbacks {
  /** Fires as soon as the medium is known — BEFORE any block is read — so the
   *  UI can show identity in about a second instead of after ~64 round trips. */
  onMeta?: (meta: DumpMeta) => void;
  onUnit: (u: DumpUnit, done: number, total: number) => void;
}

export async function dumpCard(
  dev: ChameleonDevice,
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  const tag = await dev.scanTag();
  if (tag === null) throw new TagTimeoutError('No card in the field — hold one on the reader');
  if (tag.sak === 0x08) return dumpClassic(dev, tag, cb, signal);
  if (tag.sak === 0x00) return dumpNtag(dev, tag, cb, signal);
  throw new UnsupportedTagError(
    `Unsupported tag (SAK 0x${tag.sak.toString(16)}) — Mifare Classic 1K and NTAG213/215/216 can be inspected`,
  );
}

function classicKind(block: number): UnitKind {
  if (block === 0) return 'manufacturer';
  return block % 4 === 3 ? 'trailer' : 'data';
}

async function dumpClassic(
  dev: ChameleonDevice,
  tag: { uid: Uint8Array; sak: number },
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  const meta: DumpMeta = {
    medium: 'mifare-classic-1k', sak: tag.sak, uid: tag.uid, totalUnits: CLASSIC_BLOCKS,
  };
  cb.onMeta?.(meta);
  const onUnit = cb.onUnit;
  const units: DumpUnit[] = [];
  let aborted = false;
  let cardLost = false;

  for (let block = 0; block < CLASSIC_BLOCKS; block++) {
    if (signal?.aborted) { aborted = true; break; }
    const base = { index: block, sector: Math.floor(block / 4), kind: classicKind(block) };
    let unit: DumpUnit;
    try {
      const bytes = await dev.readBlock(block, FACTORY_KEY_A);
      unit = bytes.length === BLOCK_SIZE ? { ...base, bytes } : { ...base, failure: 'short-read' };
    } catch (e) {
      if (e instanceof CardAuthError) {
        unit = { ...base, failure: 'auth-failed' };
      } else {
        // The card has almost certainly left the field. Report this block and
        // every remaining one as not-read, then stop.
        cardLost = true;
        for (let rest = block; rest < CLASSIC_BLOCKS; rest++) {
          const u: DumpUnit = {
            index: rest, sector: Math.floor(rest / 4), kind: classicKind(rest), failure: 'not-read',
          };
          units.push(u);
          onUnit(u, rest + 1, CLASSIC_BLOCKS);
        }
        break;
      }
    }
    units.push(unit);
    onUnit(unit, block + 1, CLASSIC_BLOCKS);
  }
  return { meta, units, aborted, cardLost };
}

async function dumpNtag(
  dev: ChameleonDevice,
  tag: { uid: Uint8Array; sak: number },
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  let version: Uint8Array;
  try {
    version = await dev.transceive14a(new Uint8Array([0x60]), {
      autoSelect: true, appendCrc: true, checkResponseCrc: true,
    });
  } catch {
    throw new UnsupportedTagError('Tag does not answer NTAG GET_VERSION');
  }
  const type = detectNtagType(version);
  if (type === null) {
    throw new UnsupportedTagError('Unsupported NTAG (GET_VERSION storage byte unrecognized)');
  }

  const pages = ntagTotalPages(type);
  const groups = Math.ceil(pages / PAGES_PER_READ);
  const meta: DumpMeta = { medium: type, sak: tag.sak, uid: tag.uid, totalUnits: groups };
  cb.onMeta?.(meta);
  const onUnit = cb.onUnit;
  const units: DumpUnit[] = [];
  let aborted = false;
  let cardLost = false;

  for (let group = 0; group < groups; group++) {
    if (signal?.aborted) { aborted = true; break; }
    const startPage = group * PAGES_PER_READ;
    const pagesHere = Math.min(PAGES_PER_READ, pages - startPage);
    const want = pagesHere * 4;
    const isFinal = group === groups - 1;
    // Group 0 is UID + lock bytes + Capability Container.
    const base = { index: startPage, kind: (group === 0 ? 'cc' : 'data') as UnitKind };
    let unit: DumpUnit;
    try {
      const resp = await dev.transceive14a(new Uint8Array([0x30, startPage]), {
        autoSelect: true, appendCrc: true, checkResponseCrc: true,
      });
      // A real READ always returns 4 pages and WRAPS to page 0 near the end of
      // memory, so truncate to the pages that actually exist. FakeChameleon
      // does not wrap — it returns a short slice — so a short response is
      // acceptable on the FINAL group only. Anywhere else a short read means
      // marginal RF coupling (see the CardReadError work in PR #42) and is a
      // failure. Same symptom, opposite meaning, told apart by position.
      if (resp.length >= want) {
        unit = { ...base, bytes: resp.subarray(0, want) };
      } else if (isFinal) {
        unit = { ...base, bytes: resp };
      } else {
        unit = { ...base, failure: 'short-read' };
      }
    } catch (e) {
      if (e instanceof CardAuthError) {
        unit = { ...base, failure: 'auth-failed' };
      } else {
        cardLost = true;
        for (let rest = group; rest < groups; rest++) {
          const u: DumpUnit = {
            index: rest * PAGES_PER_READ,
            kind: (rest === 0 ? 'cc' : 'data') as UnitKind,
            failure: 'not-read',
          };
          units.push(u);
          onUnit(u, rest + 1, groups);
        }
        break;
      }
    }
    units.push(unit);
    onUnit(unit, group + 1, groups);
  }
  return { meta, units, aborted, cardLost };
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -6
```

Expected: `tests 178`, `pass 178`, `fail 0` (172 + 6 new).

- [ ] **Step 6: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/src/inspect/card-dump.ts webapp/src/nfc/type2.ts webapp/test/card-dump.test.ts
git commit -m "feat(webapp): raw card dump over the ChameleonDevice seam

Reads all 64 Classic blocks or every NTAG page group, reporting each unit as it
arrives so the UI can render top-down rather than waiting out ~15-25 s of BLE
round trips. Read-only; Transport is untouched because a raw dump is not a chunk
operation.

Failure handling distinguishes two cases that look alike. A CardAuthError marks
that unit auth-failed and the dump continues — a card with one custom-keyed
sector is still mostly readable. Any other read error means the card has left
the field, so the dump marks the remainder not-read and stops instead of
grinding through dozens more failing round trips.

NTAG end-of-memory needs the same care: a real READ returns 4 pages and wraps to
page 0, while FakeChameleon returns a short slice. A short response is therefore
end-of-memory on the final group only; anywhere else it means marginal RF
coupling and is a failure. type2.ts gains ntagTotalPages() because USER_BYTES
covers only the NDEF area, not the config/lock pages a raw dump must show."
```

---

### Task 3: Text rendering

**Files:**
- Create: `webapp/src/inspect/hex-view.ts`
- Test: `webapp/test/hex-view.test.ts`

**Interfaces:**
- Consumes: `DumpUnit`, `DumpMeta` from `src/inspect/card-dump.js`; `NfarDescription` from `src/inspect/nfar-describe.js`; `CardDiagnosis` from `app/diagnostics.js`.
- Produces:
  - `formatUnitRow(u: DumpUnit): string`
  - `formatIdentity(meta: DumpMeta, diag: CardDiagnosis | null): string`
  - `formatNfar(d: NfarDescription): string`
  - `formatReport(meta, diag, nfar, units): string`

- [ ] **Step 1: Write the failing test**

Create `webapp/test/hex-view.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatUnitRow, formatIdentity, formatNfar, formatReport } from '../src/inspect/hex-view.js';
import { describeNfar } from '../src/inspect/nfar-describe.js';
import type { DumpMeta, DumpUnit } from '../src/inspect/card-dump.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { NtagType } from '../src/nfc/type2.js';

const CLASSIC_META: DumpMeta = {
  medium: 'mifare-classic-1k', sak: 0x08,
  uid: new Uint8Array([0xb9, 0x16, 0x27, 0x51]), totalUnits: 64,
};
const DIAG = {
  atqa: new Uint8Array([0x04, 0x00]),
  uidCl1: new Uint8Array([0xb9, 0x16, 0x27, 0x51]),
  bccReturned: 0xd9, bccComputed: 0xd9, bccValid: true, isCascade: false,
};

test('a data row shows sector, block, hex and printable ASCII', () => {
  const bytes = new Uint8Array([
    0x4e, 0x46, 0x41, 0x52, 0x01, 0x00, 0x98, 0x94,
    0x4a, 0x9b, 0x17, 0x88, 0x4f, 0xcc, 0xa9, 0xf9,
  ]);
  const row = formatUnitRow({ index: 1, sector: 0, kind: 'data', bytes });
  assert.match(row, /4E 46 41 52 01 00 98 94 4A 9B 17 88 4F CC A9 F9/);
  assert.match(row, /NFAR/);
  // Non-printables must not leak control characters into the report.
  assert.ok(!/[\x00-\x1f]/.test(row.replace(/\n/g, '')), row);
});

test('a trailer row is labelled as one', () => {
  const row = formatUnitRow({ index: 3, sector: 0, kind: 'trailer', bytes: new Uint8Array(16).fill(0xff) });
  assert.match(row, /trailer/i);
});

test('failed units say why and carry no hex', () => {
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'auth-failed' }), /auth failed/i);
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'not-read' }), /not read/i);
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'short-read' }), /short read/i);
  assert.ok(!/[0-9A-F]{2} [0-9A-F]{2} [0-9A-F]{2}/.test(
    formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'auth-failed' }),
  ));
});

test('identity reports a Classic BCC verdict', () => {
  const text = formatIdentity(CLASSIC_META, DIAG);
  assert.match(text, /Mifare Classic 1K/);
  assert.match(text, /04 00/);
  assert.match(text, /B9 16 27 51/);
  assert.match(text, /0xd9/i);
  assert.match(text, /OK/);
});

test('a 7-byte cascade UID is normal on NTAG and a fault on Classic', () => {
  const cascadeDiag = { ...DIAG, uidCl1: new Uint8Array([0x88, 0x04, 0xaa, 0xbb]), isCascade: true };
  const ntagMeta: DumpMeta = {
    medium: NtagType.NTAG213, sak: 0x00, uid: new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]), totalUnits: 12,
  };
  const onNtag = formatIdentity(ntagMeta, cascadeDiag);
  assert.match(onNtag, /7-byte UID/);
  assert.ok(!/not a 4-byte|MISMATCH|fault/i.test(onNtag), `cascade is normal on NTAG: ${onNtag}`);

  const onClassic = formatIdentity(CLASSIC_META, cascadeDiag);
  assert.match(onClassic, /not a 4-byte Mifare Classic/i);
});

test('identity survives a failed anticollision', () => {
  assert.match(formatIdentity(CLASSIC_META, null), /anticollision failed/i);
});

test('the NFAR panel renders flags, ids and CRC status', () => {
  const payload = new TextEncoder().encode('Test');
  const bytes = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  const text = formatNfar(describeNfar(bytes));
  assert.match(text, /NFAR/);
  assert.match(text, /chunk 1 of 1/);
  assert.match(text, /no compression/i);
  assert.match(text, /CRC32/);
  assert.match(text, /OK/);
});

test('the NFAR panel states why a card is not NFAR', () => {
  const text = formatNfar(describeNfar(new Uint8Array(32)));
  assert.match(text, /not NFAR/i);
  assert.match(text, /magic mismatch/);
});

test('unknown CRC status reads as pending, not as failure', () => {
  const payload = new TextEncoder().encode('Test');
  const full = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  const text = formatNfar(describeNfar(full.subarray(0, 28)));
  assert.ok(!/MISMATCH|FAILED/i.test(text), `pending must not look like corruption: ${text}`);
});

test('the report concatenates identity, NFAR and every row', () => {
  const units: DumpUnit[] = [
    { index: 0, sector: 0, kind: 'manufacturer', bytes: new Uint8Array(16) },
    { index: 1, sector: 0, kind: 'data', failure: 'auth-failed' },
  ];
  const report = formatReport(CLASSIC_META, DIAG, describeNfar(new Uint8Array(32)), units);
  assert.match(report, /Mifare Classic 1K/);
  assert.match(report, /not NFAR/i);
  assert.match(report, /auth failed/i);
  assert.ok(report.split('\n').length > 5);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc 2>&1 | head -3
```

Expected: FAIL — `Cannot find module '../src/inspect/hex-view.js'`.

- [ ] **Step 3: Write the implementation**

Create `webapp/src/inspect/hex-view.ts`:

```ts
/**
 * Text rendering of a card dump: one line per unit for the dialog, plus the
 * whole plain-text report for Copy/Download. Kept out of the DOM layer so the
 * exact output is unit-testable — the report is what gets pasted into bug
 * reports, so its content matters.
 */
import type { CardDiagnosis } from '../../app/diagnostics.js';
import type { DumpMeta, DumpUnit } from './card-dump.js';
import type { NfarDescription } from './nfar-describe.js';

const HEX_WIDTH = 16 * 3 - 1; // "FF FF ... FF"

const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

/** Printable ASCII only; everything else becomes '.' so no control character
 *  can corrupt a pasted report. */
const ascii = (b: Uint8Array): string =>
  Array.from(b, (x) => (x >= 0x20 && x <= 0x7e ? String.fromCharCode(x) : '.')).join('');

const byte = (n: number): string => `0x${n.toString(16).padStart(2, '0')}`;
const u32 = (n: number): string => n.toString(16).padStart(8, '0');

const FAILURE_TEXT: Record<NonNullable<DumpUnit['failure']>, string> = {
  'auth-failed': 'auth failed (non-factory key)',
  'not-read': 'not read (card left the field)',
  'short-read': 'short read (marginal coupling)',
};

export function formatUnitRow(u: DumpUnit): string {
  const label = u.sector === undefined
    ? `pg ${String(u.index).padStart(3)}`
    : `s${String(u.sector).padStart(2)} b${String(u.index).padStart(2)}`;
  if (u.bytes === undefined) {
    const why = u.failure ? FAILURE_TEXT[u.failure] : 'unavailable';
    return `${label}  ${`── ${why} ──`.padEnd(HEX_WIDTH)}`;
  }
  const note = u.kind === 'trailer' ? '  ← sector trailer'
    : u.kind === 'manufacturer' ? '  ← manufacturer block'
    : u.kind === 'cc' ? '  ← UID / lock / capability container'
    : '';
  return `${label}  ${hex(u.bytes).padEnd(HEX_WIDTH)}  ${ascii(u.bytes)}${note}`;
}

export function formatIdentity(meta: DumpMeta, diag: CardDiagnosis | null): string {
  const medium = meta.medium === 'mifare-classic-1k' ? 'Mifare Classic 1K' : meta.medium;
  const lines = [`Medium    ${medium} (SAK ${byte(meta.sak)})`, `UID       ${hex(meta.uid)}`];
  if (diag === null) {
    lines.push('BCC       anticollision failed — identity unavailable (the dump may still work)');
    return lines.join('\n');
  }
  lines.push(`ATQA      ${hex(diag.atqa)}`);
  lines.push(`UID (CL1) ${hex(diag.uidCl1)}`);
  lines.push(
    `BCC       returned ${byte(diag.bccReturned)} · computed ${byte(diag.bccComputed)} · ` +
    (diag.bccValid ? 'OK' : 'MISMATCH'),
  );
  // A 7-byte cascade UID is entirely normal on NTAG; it is only a fault when the
  // SAK says this should be a 4-byte Mifare Classic 1K.
  if (diag.isCascade) {
    lines.push(meta.medium === 'mifare-classic-1k'
      ? 'Verdict   7-byte UID (cascade tag) — not a 4-byte Mifare Classic 1K'
      : 'Verdict   7-byte UID (cascade tag) — normal for NTAG');
  } else if (!diag.bccValid) {
    lines.push('Verdict   malformed block-0 UID (a UID-writable "magic" card); rewrite block 0 with a correct BCC');
  } else {
    lines.push('Verdict   BCC OK');
  }
  return lines.join('\n');
}

export function formatNfar(d: NfarDescription): string {
  if (!d.present) return `not NFAR: ${d.reason}`;
  const flagText = [
    d.compressed ? 'GZIP' : 'no compression',
    d.encrypted ? 'AES-256-GCM' : 'no encryption',
  ].join(', ');
  const lines = [
    `magic     NFAR  v${d.version}  flags ${byte(d.flags)} (${flagText})`,
    `archive   ${d.archiveId}`,
    `chunk     ${d.chunkIndex + 1} of ${d.totalChunks}`,
    `payload   ${d.payloadSize} B    chunk total ${d.totalLength} B`,
  ];
  if (d.crcStored === null || d.crcComputed === null) {
    lines.push('CRC32     pending — the dump has not reached the tail yet');
  } else {
    lines.push(
      `CRC32     stored ${u32(d.crcStored)} · computed ${u32(d.crcComputed)} · ` +
      (d.crcValid ? 'OK' : 'MISMATCH'),
    );
  }
  for (const w of d.warnings) lines.push(`warning   ${w}`);
  return lines.join('\n');
}

export function formatReport(
  meta: DumpMeta,
  diag: CardDiagnosis | null,
  nfar: NfarDescription,
  units: DumpUnit[],
): string {
  return [
    'NFC Archiver — card inspection',
    '',
    'IDENTITY',
    formatIdentity(meta, diag),
    '',
    'NFAR CHUNK',
    formatNfar(nfar),
    '',
    `RAW (${units.length} of ${meta.totalUnits} units)`,
    ...units.map(formatUnitRow),
    '',
  ].join('\n');
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -6
```

Expected: `tests 188`, `pass 188`, `fail 0` (178 + 10 new).

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/src/inspect/hex-view.ts webapp/test/hex-view.test.ts
git commit -m "feat(webapp): text rendering for the card inspector

One line per dump unit for the dialog, plus the full plain-text report for
Copy/Download. Kept out of the DOM layer so the exact output is unit-testable —
the report is what gets pasted into a bug report, so its content matters.

Two things the tests pin. Non-printable bytes always render as '.', so no
control character can corrupt a pasted report. And a 7-byte cascade UID reads as
a fault only when the SAK says Classic: the old wording called it 'not a 4-byte
Mifare Classic 1K' unconditionally, which is wrong on every NTAG, all of which
have 7-byte UIDs.

Pending CRC status renders as 'pending', never as MISMATCH — the panel is drawn
before the dump reaches the tail, and a premature MISMATCH would read as
corruption."
```

---

### Task 4: DOM-free inspection orchestrator

**Files:**
- Create: `webapp/app/ui/inspect-orchestrator.ts`
- Test: `webapp/test/inspect-orchestrator.test.ts`

**Interfaces:**
- Consumes: `dumpCard`, `DumpUnit`, `DumpResult` from `src/inspect/card-dump.js`; `describeNfar` from `src/inspect/nfar-describe.js`; `formatIdentity`, `formatNfar`, `formatUnitRow`, `formatReport` from `src/inspect/hex-view.js`; `diagnoseCard`, `RawAntiColl` from `app/diagnostics.js`.
- Produces: `runInspection(dev: ChameleonDevice, raw: RawAntiColl, io: InspectIO, signal?: AbortSignal): Promise<void>` and `interface InspectIO`.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/inspect-orchestrator.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInspection, type InspectIO } from '../app/ui/inspect-orchestrator.js';
import type { RawAntiColl } from '../app/diagnostics.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { chunkToBlocks } from '../src/mifare/card-layout.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { FakeChameleon } from './fake-chameleon.js';

const UID = new Uint8Array([0xb9, 0x16, 0x27, 0x51]);

/** Records everything the orchestrator pushed, in order. */
function stubIo() {
  const calls: string[] = [];
  const rows: string[] = [];
  const io: InspectIO = {
    setIdentity: (t) => { calls.push('identity'); void t; },
    setNfar: (t) => { calls.push(`nfar:${t.split('\n')[0]}`); },
    appendRow: (line) => { calls.push('row'); rows.push(line); },
    setProgress: (t) => { calls.push(`progress:${t}`); },
    setReport: () => { calls.push('report'); },
    setStatus: (t) => { calls.push(`status:${t}`); },
  };
  return { io, calls, rows };
}

/** Put a real NFAR chunk on a fake Classic card. */
async function writeChunk(device: FakeChameleon): Promise<void> {
  const payload = new TextEncoder().encode('Test');
  const bytes = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  for (const { block, data } of chunkToBlocks(bytes)) {
    await device.writeBlock(block, FACTORY_KEY_A, data);
  }
}

const okRaw: RawAntiColl = {
  async transceive(data) {
    // 7-bit WUPA -> ATQA; anticollision CL1 -> UID + BCC.
    if (data[0] === 0x52) return new Uint8Array([0x04, 0x00]);
    return new Uint8Array([0xb9, 0x16, 0x27, 0x51, 0xd9]);
  },
};

test('identity and the NFAR panel appear before the dump finishes', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  await writeChunk(device);
  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const identityAt = calls.indexOf('identity');
  const nfarAt = calls.findIndex((c) => c.startsWith('nfar:'));
  const lastRowAt = calls.lastIndexOf('row');
  assert.ok(identityAt >= 0 && identityAt < lastRowAt, 'identity must precede the last row');
  assert.ok(nfarAt >= 0 && nfarAt < lastRowAt, 'the NFAR panel must precede the last row');
});

test('rows arrive progressively, one per unit, with progress reported', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const { io, calls, rows } = stubIo();
  await runInspection(device, okRaw, io);

  assert.equal(rows.length, 64);
  assert.ok(calls.some((c) => c === 'progress:reading… 1/64'));
  assert.ok(calls.some((c) => c === 'progress:64/64 read'));
  assert.ok(calls.includes('report'), 'the report must be assembled at the end');
});

test('a real chunk on the card is decoded, CRC verified', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  await writeChunk(device);
  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /NFAR/);
  assert.ok(!/not NFAR/.test(nfar), nfar);
});

test('a blank card reports not-NFAR and still dumps', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const { io, calls, rows } = stubIo();
  await runInspection(device, okRaw, io);

  assert.ok(calls.some((c) => /not NFAR/.test(c)));
  assert.equal(rows.length, 64, 'the raw dump is unaffected by the card not being NFAR');
});

test('a failed anticollision does not stop the dump', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const badRaw: RawAntiColl = { async transceive() { throw new Error('no response'); } };
  const { io, calls, rows } = stubIo();
  await runInspection(device, badRaw, io);

  assert.ok(calls.some((c) => c === 'identity'), 'identity is still rendered');
  assert.equal(rows.length, 64, 'readBlock does its own select, so the dump proceeds');
});

test('an aborted inspection reports it and stops early', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const ac = new AbortController();
  const rows: string[] = [];
  const { io } = stubIo();
  const io2: InspectIO = { ...io, appendRow: (l) => { rows.push(l); if (rows.length === 4) ac.abort(); } };
  await runInspection(device, okRaw, io2, ac.signal);

  assert.ok(rows.length < 64, `expected an early stop, got ${rows.length}`);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc 2>&1 | head -3
```

Expected: FAIL — `Cannot find module '../app/ui/inspect-orchestrator.js'`.

- [ ] **Step 3: Write the implementation**

Create `webapp/app/ui/inspect-orchestrator.ts`:

```ts
/**
 * DOM-free inspection flow behind an injected IO seam, following the same
 * pattern as RestoreOrchestrator and ArchiveOrchestrator. The panel supplies
 * real DOM IO; tests supply a plain object, which is why nothing here needs a
 * DOM stub.
 *
 * Order matters: identity first (two frames, ~1 s), then the dump, with the
 * NFAR panel refreshed as soon as enough data blocks have arrived to describe
 * the header. That way the user sees the useful parts long before the ~64 BLE
 * round trips finish.
 */
import { dumpCard, type DumpUnit } from '../../src/inspect/card-dump.js';
import { describeNfar, type NfarDescription } from '../../src/inspect/nfar-describe.js';
import { formatIdentity, formatNfar, formatReport, formatUnitRow } from '../../src/inspect/hex-view.js';
import { USABLE_BLOCK_INDEXES } from '../../src/mifare/card-layout.js';
import type { ChameleonDevice } from '../../src/transport/chameleon-device.js';
import { diagnoseCard, type CardDiagnosis, type RawAntiColl } from '../diagnostics.js';
import { humanError } from './errors.js';

export interface InspectIO {
  setIdentity(text: string): void;
  setNfar(text: string): void;
  appendRow(line: string): void;
  setProgress(text: string): void;
  setReport(text: string): void;
  setStatus(text: string): void;
}

/** NFAR bytes live in the usable blocks (block 0 and sector trailers skipped)
 *  for Classic, and from page 4 for NTAG. Rebuild that stream from the units
 *  seen so far so the header can be described mid-dump. */
function nfarBytesSoFar(units: DumpUnit[], isClassic: boolean): Uint8Array {
  const wanted = isClassic
    ? units.filter((u) => USABLE_BLOCK_INDEXES.includes(u.index))
    : units.filter((u) => u.index >= 4);
  const parts: Uint8Array[] = [];
  for (const u of wanted) {
    if (u.bytes === undefined) break; // a gap makes everything after it meaningless
    parts.push(u.bytes);
  }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

export async function runInspection(
  dev: ChameleonDevice,
  raw: RawAntiColl,
  io: InspectIO,
  signal?: AbortSignal,
): Promise<void> {
  io.setStatus('Hold the card still on the reader…');

  // The anticollision is advisory: readBlock performs its own select, so a
  // failure here must not stop the dump.
  let diag: CardDiagnosis | null = null;
  try {
    diag = await diagnoseCard(raw);
  } catch {
    diag = null;
  }

  let nfar: NfarDescription = { present: false, reason: 'no data read yet' };
  const seen: DumpUnit[] = [];

  try {
    const result = await dumpCard(dev, {
      // Fires before the first read, so identity is on screen in about a second
      // rather than after ~64 BLE round trips.
      onMeta: (meta) => { io.setIdentity(formatIdentity(meta, diag)); },
      onUnit: (unit, done, total) => {
        seen.push(unit);
        io.appendRow(formatUnitRow(unit));
        io.setProgress(done === total ? `${done}/${total} read` : `reading… ${done}/${total}`);
        // Re-describe while the NFAR extent is still growing; once the declared
        // tail is covered the description stops changing.
        if (nfar.present === false || nfar.crcValid === null) {
          nfar = describeNfar(nfarBytesSoFar(seen, unit.sector !== undefined));
          io.setNfar(formatNfar(nfar));
        }
      },
    }, signal);

    io.setNfar(formatNfar(nfar));
    io.setReport(formatReport(result.meta, diag, nfar, result.units));
    io.setStatus(
      result.aborted ? 'Stopped.'
        : result.cardLost ? 'Card left the field — re-tap and inspect again.'
        : 'Done.',
    );
  } catch (e) {
    io.setStatus(humanError(e));
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -6
```

Expected: `tests 194`, `pass 194`, `fail 0` (188 + 6 new).

The first test is the specification for ordering: identity MUST be rendered
before the last row. That is why `dumpCard` takes an `onMeta` callback — the
medium is known before any read, so identity must not wait on the dump. If this
test fails, the bug is in the wiring, not the test.

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/app/ui/inspect-orchestrator.ts webapp/test/inspect-orchestrator.test.ts
git commit -m "feat(webapp): DOM-free inspection orchestrator

runInspection drives diagnose -> dump -> describe through an injected InspectIO
seam, matching RestoreOrchestrator and ArchiveOrchestrator. Because the seam is
a plain object, the progressive-rendering behaviour is testable without any DOM
stub.

The anticollision is advisory: readBlock performs its own select, so a failed
diagnose renders 'anticollision failed' in the identity block and the dump
proceeds regardless.

The NFAR header is re-described as data blocks arrive, rebuilding the chunk
stream from the usable blocks only (block 0 and sector trailers are not part of
it), and stops re-describing once the declared tail is covered. A gap in the
stream truncates it — bytes after a missing block cannot be interpreted."
```

---

### Task 5: The dialog, wiring, and docs

**Files:**
- Create: `webapp/app/ui/inspect-panel.ts`
- Modify: `webapp/app/index.html` (button at line 78; new `<dialog>` beside `overwrite-dialog` at line 158)
- Modify: `webapp/app/ui/device.ts` (button id/label, `setReaderBusy`, open the panel)
- Modify: `webapp/app/ui/archive-panel.ts` and `webapp/app/ui/restore-panel.ts` (report busy)
- Modify: `webapp/README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `runInspection`, `InspectIO` from `app/ui/inspect-orchestrator.js`.
- Produces: `openInspector(dev: ChameleonDevice, raw: RawAntiColl): void` from `app/ui/inspect-panel.js`; `setReaderBusy(busy: boolean): void` from `app/ui/device.js`.

- [ ] **Step 1: Replace the button and add the dialog markup**

In `webapp/app/index.html`, change line 78 from:

```html
      <button id="diagnose" disabled>Diagnose card</button>
```

to:

```html
      <button id="inspect" disabled>Inspect card</button>
```

Then add this immediately after the closing `</dialog>` of `overwrite-dialog`
(after line 165):

```html
    <dialog id="inspect-dialog" class="inspect">
      <div class="inspect-head">
        <strong>Inspect card</strong>
        <span id="inspect-progress" class="muted"></span>
        <span class="inspect-actions">
          <button id="inspect-copy" type="button">Copy</button>
          <button id="inspect-download" type="button">Download</button>
          <button id="inspect-close" type="button">Close</button>
        </span>
      </div>
      <p id="inspect-status" class="muted"></p>
      <h4>Identity</h4>
      <pre id="inspect-identity"></pre>
      <h4>NFAR chunk</h4>
      <pre id="inspect-nfar"></pre>
      <h4>Raw</h4>
      <pre id="inspect-raw"></pre>
    </dialog>
```

Add to the existing `<style>` block:

```css
      dialog.inspect { max-width: min(96vw, 62rem); max-height: 88vh; overflow: auto; }
      .inspect-head { display: flex; align-items: baseline; gap: 0.6rem; flex-wrap: wrap; }
      .inspect-actions { margin-left: auto; display: flex; gap: 0.4rem; }
      dialog.inspect pre { overflow-x: auto; font-size: 0.78rem; line-height: 1.35; margin: 0.2rem 0 0.8rem; }
      dialog.inspect h4 { margin: 0.6rem 0 0.1rem; }
```

- [ ] **Step 2: Write the panel**

Create `webapp/app/ui/inspect-panel.ts`:

```ts
/**
 * The Inspect card dialog: a thin adapter binding the DOM to InspectIO. All
 * logic lives in inspect-orchestrator.ts; this file only moves strings into
 * elements and wires Copy/Download/Close.
 *
 * Closing the dialog aborts the remaining reads — a full dump is ~64 BLE round
 * trips, and there is no reason to keep the reader busy once nobody is looking.
 */
import { runInspection, type InspectIO } from './inspect-orchestrator.js';
import type { ChameleonDevice } from '../../src/transport/chameleon-device.js';
import type { RawAntiColl } from '../diagnostics.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

let running = false;

export function openInspector(dev: ChameleonDevice, raw: RawAntiColl): void {
  if (running) return;
  const dialog = $('inspect-dialog') as HTMLDialogElement;
  const identity = $('inspect-identity');
  const nfar = $('inspect-nfar');
  const rawPre = $('inspect-raw');
  const progress = $('inspect-progress');
  const status = $('inspect-status');

  identity.textContent = '';
  nfar.textContent = '';
  rawPre.textContent = '';
  progress.textContent = '';
  status.textContent = '';

  let report = '';
  const rows: string[] = [];
  const io: InspectIO = {
    setIdentity: (t) => { identity.textContent = t; },
    setNfar: (t) => { nfar.textContent = t; },
    appendRow: (line) => { rows.push(line); rawPre.textContent = rows.join('\n'); },
    setProgress: (t) => { progress.textContent = t; },
    setReport: (t) => { report = t; },
    setStatus: (t) => { status.textContent = t; },
  };

  const ac = new AbortController();
  const onClose = () => ac.abort();
  dialog.addEventListener('close', onClose, { once: true });
  $('inspect-close').addEventListener('click', () => dialog.close(), { once: true });

  $('inspect-copy').addEventListener('click', () => {
    void navigator.clipboard.writeText(report || rows.join('\n'));
  }, { once: true });

  $('inspect-download').addEventListener('click', () => {
    const blob = new Blob([report || rows.join('\n')], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `card-inspection-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  }, { once: true });

  dialog.showModal();
  running = true;
  log.info('inspect', 'Inspection started');
  void runInspection(dev, raw, io, ac.signal)
    .catch((e: unknown) => { status.textContent = String(e); })
    .finally(() => {
      running = false;
      log.info('inspect', 'Inspection finished', { rows: rows.length });
    });
}
```

- [ ] **Step 3: Wire it in `device.ts`**

In `webapp/app/ui/device.ts`:

Replace the `diagnoseCard` import (line 11) with:

```ts
import { type RawAntiColl } from '../diagnostics.js';
import { openInspector } from './inspect-panel.js';
```

Remove the now-unused `hex` helper (lines 16–17) — the inspector formats its own
hex. Add the busy flag and button updater after the `connected` declaration:

```ts
let readerBusy = false;

/** Panels report when they own the reader. Two callers interleaving BLE
 *  commands on one reader can corrupt an in-flight write, which is why the
 *  Archive button already guards on its own `archiving` flag. */
export function setReaderBusy(busy: boolean): void {
  readerBusy = busy;
  updateInspectButton();
}

function updateInspectButton(): void {
  ($('inspect') as HTMLButtonElement).disabled = !connected || readerBusy;
}
```

In the `'disconnected'` handler, replace
`($('diagnose') as HTMLButtonElement).disabled = true;` with
`updateInspectButton();` (it reads `connected`, already set to `false` above it).

In the connect success path, replace
`($('diagnose') as HTMLButtonElement).disabled = false;` with nothing, and move
`updateInspectButton();` to immediately after `connected = true;`.

Replace the whole `$('diagnose').addEventListener(...)` block (lines 77–109) with:

```ts
  $('inspect').addEventListener('click', () => {
    if (!ultra || !transport) return;
    const dev = ultra;
    const raw: RawAntiColl = {
      async transceive(data, opts) {
        const resp = await dev.cmdHf14aRaw({
          data: Buffer.from(data),
          dataBitLength: opts?.dataBitLength ?? 0,
          activateRfField: opts?.activateRfField ?? false,
          keepRfField: opts?.keepRfField ?? false,
          checkResponseCrc: false,
          waitResponse: true,
        });
        return new Uint8Array(resp);
      },
    };
    openInspector(new SdkChameleonDevice(dev), raw);
  });
```

- [ ] **Step 4: Report busy from both panels**

In `webapp/app/ui/archive-panel.ts`, add `setReaderBusy` to the `device.js`
import, then inside the `$('archive')` click handler set it around the run:

```ts
    archiving = true;
    setReaderBusy(true);
    ($('archive') as HTMLButtonElement).disabled = true;
```

and in the existing `finally` block add `setReaderBusy(false);` as its first
statement.

In `webapp/app/ui/restore-panel.ts`, add `setReaderBusy` to the `device.js`
import, then in the `$('scan')` click handler add `setReaderBusy(true);`
immediately after `setStatus('Scanning — tap cards on the reader…');`, and
`setReaderBusy(false);` as the first statement of the existing `finally` block.

- [ ] **Step 5: Typecheck, test, and build**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -6
BUILD_SHA=$(git rev-parse --short=7 HEAD) npm run build:site 2>&1 | tail -1
```

Expected: `tests 194`, `pass 194`, `fail 0`, and the build reports
`site/ built and verified`. A `tsc` error naming `diagnose` means a rename was
missed in Step 3.

- [ ] **Step 6: Check the dialog by hand**

```bash
cd webapp && npm run app
```

In Chrome with a Chameleon connected: click **Inspect card** with a Mifare
Classic on the reader. Confirm identity appears within a second or so, the NFAR
panel populates before the dump finishes, rows stream in, and Copy puts the whole
report on the clipboard. Then start a scan on the Restore tab and confirm
**Inspect card** greys out.

- [ ] **Step 7: Update the docs**

In `webapp/README.md`, replace the Features bullet that currently reads
`- **Diagnose card** — reads a card's raw UID + BCC (bypassing the reader's BCC check) to explain read failures.`
with:

```markdown
- **Inspect card** — dumps the presented card in a modal: identity (ATQA, UID,
  BCC — computed manually, bypassing the reader's own BCC check, so malformed
  "magic" cards are still identifiable), the decoded NFAR chunk header with
  CRC32 verification, and a raw hex/ASCII view of every block or page. Rendered
  progressively as the ~64 BLE reads arrive; Copy/Download give a plain-text
  report. Read-only, and disabled while an archive write or scan owns the reader.
```

In `CLAUDE.md`, add to the Web App bullet list after the **Media** bullet:

```markdown
- **Card inspector:** the device-bar "Inspect card" button dumps the presented card into a modal — identity, decoded NFAR header with CRC verification, and raw hex/ASCII per block/page. Logic is in `src/inspect/` (dependency-free: `card-dump.ts`, `nfar-describe.ts`, `hex-view.ts`) plus `app/ui/inspect-orchestrator.ts` behind an `InspectIO` seam, so it is tested without a DOM stub. `describeNfar` is deliberately tolerant where `decodeChunk` throws — in an inspector the failure is the information. Read-only; `Transport` is untouched because a raw dump is not a chunk operation.
```

- [ ] **Step 8: Commit and push**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/app/ui/inspect-panel.ts webapp/app/index.html webapp/app/ui/device.ts \
        webapp/app/ui/archive-panel.ts webapp/app/ui/restore-panel.ts \
        webapp/README.md CLAUDE.md
git commit -m "feat(webapp): Inspect card dialog replacing Diagnose card

A native <dialog> showing identity, the decoded NFAR header, and a raw
hex/ASCII dump, filled in progressively as the ~64 BLE reads arrive. Closing it
aborts the remaining reads. Copy/Download produce a plain-text report.

The old BCC/anticollision diagnostic is not lost — it is the identity block, and
remains the app's only way to identify a malformed-block-0 magic card that the
reader firmware rejects outright.

device.ts gains setReaderBusy(), reported by the archive and restore panels, so
Inspect is disabled while something else owns the reader. Two callers
interleaving BLE commands could corrupt an in-flight write; neither panel
previously exposed that it was driving the reader."
git push
```

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| One button, relabelled `Inspect card` | 5 |
| BCC diagnostic folded into identity, not dropped | 3 (`formatIdentity`) + 4 (advisory call) |
| Raw dump + decoded NFAR header with CRC | 1, 2, 3 |
| No payload preview / filename unwrap | — (absent by construction) |
| Full dump, both media | 2 |
| Progressive rendering | 4, 5 |
| Per-sector auth failure does not abort | 2 |
| Card removed mid-dump → rest `not read` | 2 |
| Copy/Download as plain text | 3 (`formatReport`), 5 |
| Disabled while reader busy | 5 |
| `DumpUnit` shape | 2 |
| Identity before the dump completes | 2 (`onMeta`) + 4 |
| NTAG wrap / short-read-only-at-end | 2 |
| Medium-aware cascade verdict | 3 |
| `describeNfar` tolerant, partial buffers | 1 |
| Nothing writes to a card | all — no `writeBlock`/`0xA2` outside test setup |
| Not-NFAR card still dumps | 4 |
| Unsupported SAK explains supported media | 2 |
| Tests per spec's testing section | 1–4 |

Two deliberate deviations from the spec, both improvements:

1. **The dialog is split into orchestrator + panel** rather than a single
   `inspect-dialog.ts`. The spec's plan needed a DOM stub to test progressive
   rendering; this needs none, and it matches `restore-orchestrator`/
   `restore-panel`. The spec's `inspect-dialog.test.ts` is therefore replaced by
   `inspect-orchestrator.test.ts`.
2. **`formatReport` lives in `hex-view.ts`**, so the exact text that gets pasted
   into bug reports is unit-tested rather than assembled in the DOM layer.

One spec detail corrected: the spec said `FakeChameleon.defineCard` makes the
per-sector auth case testable, but its `keyA` is per **card**, not per sector.
Task 2's test therefore covers the whole-card case and the plan says so; the
per-sector path is the same code branch.

A pre-flight scan caught a third issue, in this plan's own first draft:
`runInspection` rendered identity only after `dumpCard` resolved, which cannot
satisfy Task 4's own ordering test, and the draft hid that behind an "if the test
fails, move the call" instruction. `dumpCard` now takes a `DumpCallbacks` object
whose `onMeta` fires before the first read — the medium is known from `scanTag`
(Classic) or `GET_VERSION` (NTAG), so making the UI wait on 64 round trips for it
was simply wrong. Task 2 asserts the ordering directly.

**Placeholder scan:** none. Every code step carries the full file or exact
replacement lines.

**Type consistency:** `DumpUnit` / `DumpMeta` / `DumpResult` / `UnitKind` /
`UnitFailure` are defined in Task 2 and used with those names in Tasks 3–4.
`NfarDescription` / `NfarPresent` / `NfarAbsent` from Task 1 are used in Tasks 3–4.
`InspectIO` members (`setIdentity`, `setNfar`, `appendRow`, `setProgress`,
`setReport`, `setStatus`) match between Task 4's interface, Task 4's stub, and
Task 5's panel. `ntagTotalPages` is added in Task 2 Step 1 and used in Task 2
Step 4 and Task 2's test. `formatUnitRow` / `formatIdentity` / `formatNfar` /
`formatReport` match between Task 3 and Task 4.
