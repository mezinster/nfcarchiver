# Web NFC Reader + Disconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the web app read and write NTAG cards using the phone's own NFC radio, selectable alongside the Chameleon Ultra, and give the device bar the Disconnect button it never had.

**Architecture:** `WebNfcTransport` implements the existing `Transport` interface behind an `NdefIO` seam, so it is testable under `node --test` where `NDEFReader` does not exist. Everything above `Transport` — the archive loop, restore orchestrator, overwrite prompt — is untouched. The device bar becomes an explicit reader picker.

**Tech Stack:** TypeScript, esbuild, `node --test`, Web NFC (`NDEFReader`, Chrome on Android only).

**Source spec:** `docs/superpowers/specs/2026-07-31-webapp-web-nfc-design.md`

## Global Constraints

- **Node ≥ 22.** Prefix every command with `source ~/.nvm/nvm.sh && nvm use --lts` — the shell default is Node 14.
- **Always `rm -rf dist && npm test`**, never bare `npm test`.
- **All commands run from `webapp/`.**
- **No new runtime dependencies.** `chameleon-ultra.js` remains the only one, importable ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`.
- **`src/` must stay importable under `node --test`.** No module-level access to `NDEFReader`, `document`, `navigator` or `window`. Browser access is confined to `BrowserNdefIO`.
- **`t` is an ESM live binding.** Read `t.key` inside functions; never destructure it or capture it at module scope.
- **All new user-facing strings go in `app/i18n/en.ts` AND all six translation catalogues** (`ru`, `uk`, `be`, `pl`, `tr`, `ka`). `tsc` fails until every locale has the key — that is the completeness gate.
- **Log entries stay English.** No `log.*` call may route its message through `t`.
- **Commit style:** `feat(webapp): …` / `test(webapp): …`, ending with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `src/transport/ndef-io.ts` | The `NdefIO` seam plus its record types. No browser globals. |
| `src/transport/web-nfc-transport.ts` | `Transport` implementation over `NdefIO`. |
| `app/ui/browser-ndef-io.ts` | Wraps the real `NDEFReader`; maps DOM errors to typed ones. |
| `test/fake-ndef-io.ts` | Test double, alongside `fake-chameleon.ts`. |
| `test/web-nfc-transport.test.ts` | Contract suite + Web-NFC-specific behaviour. |

**Modified:** `test/transport-contract.ts`, `test/ntag-transport.test.ts`, `src/nfc/type2.ts`, `test/type2.test.ts`, `app/index.html`, `app/ui/device.ts`, `app/ui/archive-panel.ts`, `app/i18n/*.ts` (7), `test/i18n.test.ts`, `webapp/README.md`, `CLAUDE.md`.

**Task order rationale:** the contract suite is parameterized first so every later transport can join it; the capacity helper and the seam come before the transport that needs them; the browser wrapper and UI land last, since they are the only parts that cannot be tested headlessly.

---

### Task 1: Parameterize the shared transport contract

**Files:**
- Modify: `test/transport-contract.ts`, `test/ntag-transport.test.ts`

**Interfaces:**
- Produces: `runTransportContract(name, make, expected)` where `expected` is `{ capacityBytes: number; maxChunkPayload: number }`.

`runTransportContract` currently hardcodes `CARD_CAPACITY_BYTES` (752) and `CARD_PAYLOAD_SIZE` (720) from the Mifare layout, so only Mifare-shaped transports can use it. `NtagTransport` never joins it today. Parameterizing unlocks both `NtagTransport` and `WebNfcTransport`.

- [ ] **Step 1: Make the existing callers pass expectations explicitly**

Read `test/transport-contract.ts` in full first. Change the signature to:

```ts
export function runTransportContract(
  name: string,
  make: () => { transport: Transport; tap: (uid: Uint8Array) => void },
  expected: { capacityBytes: number; maxChunkPayload: number },
): void {
```

Replace every use of `CARD_CAPACITY_BYTES` with `expected.capacityBytes` and every `CARD_PAYLOAD_SIZE` with `expected.maxChunkPayload`, and drop the now-unused imports from `../src/mifare/card-layout.js` **except** `CardCapacityError`, which the over-capacity test still asserts on.

Update the test name on line 30 from the hardcoded `752-byte capacity` to a template:

```ts
  test(`${name}: awaitTag returns uid + ${expected.capacityBytes}-byte capacity`, async () => {
```

- [ ] **Step 2: Update the two existing callers**

In `test/chameleon-ble.test.ts` and `test/transport.test.ts`, add the third argument:

```ts
}, { capacityBytes: CARD_CAPACITY_BYTES, maxChunkPayload: CARD_PAYLOAD_SIZE });
```

importing those constants locally in each test file if not already present.

- [ ] **Step 3: Run the suite and verify nothing changed**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npm test
```

Expected: PASS with the same count as before this task. This is a pure refactor of test infrastructure.

- [ ] **Step 4: Enrol `NtagTransport` in the contract**

Append to `test/ntag-transport.test.ts`:

```ts
import { runTransportContract } from './transport-contract.js';

// An NTAG215's CC declares a 496 B NDEF area, so its usable chunk payload is
// chunkPayloadForCapacity(496) = 420 — smaller than raw user memory (504).
runTransportContract('NtagTransport+FakeChameleon', () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  return {
    transport: t,
    tap: (uid: Uint8Array) => { device.placeNtag(uid, NtagType.NTAG215); },
  };
}, { capacityBytes: 504, maxChunkPayload: chunkPayloadForCapacity(496) });
```

- [ ] **Step 5: Run and fix what the new coverage exposes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, with more tests than before. **If a contract test fails against `NtagTransport`, that is a real gap in `NtagTransport`, not a bad test** — the whole point of the suite is that every transport behaves alike. Read the failure carefully before changing anything, and if the fix would alter `NtagTransport`'s production behaviour, stop and report rather than adapting the contract to fit.

- [ ] **Step 6: Commit**

```bash
git add webapp/test/transport-contract.ts webapp/test/chameleon-ble.test.ts webapp/test/transport.test.ts webapp/test/ntag-transport.test.ts
git commit -m "test(webapp): parameterize the transport contract and enrol NtagTransport"
```

---

### Task 2: Factory NDEF capacity per NTAG type

**Files:**
- Modify: `src/nfc/type2.ts`, `test/type2.test.ts`

**Interfaces:**
- Consumes: `NtagType`, `chunkPayloadForCapacity` (both already in `src/nfc/type2.ts`).
- Produces: `ntagFactoryNdefCapacity(t: NtagType): number`, `webNfcChunkPayload(t: NtagType): number`.

Web NFC exposes no capability container, so a transport using it cannot read the tag's declared NDEF area. It must assume the factory value. Using `ntagChunkPayloadSize` instead would size against **raw user memory** (504 for NTAG215 → 428) and overflow the 496 B CC area — exactly the bug fixed in PR #41 and again in #48/#49.

- [ ] **Step 1: Write the failing test**

Append to `test/type2.test.ts`:

```ts
test('ntagFactoryNdefCapacity returns the CC-declared area, not raw memory', () => {
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG213), 144);
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG215), 496);
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG216), 872);
});

test('webNfcChunkPayload matches what the Chameleon path writes', () => {
  // The Chameleon reads the real CC and sizes from it. Web NFC cannot, so it
  // assumes the factory value — the two must agree or cards written by the two
  // readers would differ.
  assert.equal(webNfcChunkPayload(NtagType.NTAG215), chunkPayloadForCapacity(496));
  assert.equal(webNfcChunkPayload(NtagType.NTAG215), 420);
});

test('webNfcChunkPayload is never larger than the raw-memory estimate', () => {
  for (const t of [NtagType.NTAG213, NtagType.NTAG215, NtagType.NTAG216]) {
    assert.ok(webNfcChunkPayload(t) <= ntagChunkPayloadSize(t), `${t} overflows`);
  }
});
```

Add `ntagFactoryNdefCapacity` and `webNfcChunkPayload` to the file's existing import from `../src/nfc/type2.js`.

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — `ntagFactoryNdefCapacity` is not exported.

- [ ] **Step 3: Write the implementation**

Append to `src/nfc/type2.ts`:

```ts
/** NDEF data area each NTAG type declares in its FACTORY Capability Container
 *  (MLEN x 8). Smaller than raw user memory: NTAG215 496 vs 504, NTAG216 872 vs
 *  888, NTAG213 144 == 144. */
const FACTORY_CC_BYTES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 144,
  [NtagType.NTAG215]: 496,
  [NtagType.NTAG216]: 872,
};

export function ntagFactoryNdefCapacity(t: NtagType): number {
  return FACTORY_CC_BYTES[t];
}

/** Chunk payload for a reader that cannot read the tag's own Capability
 *  Container — Web NFC. Assumes the factory CC, which is what an unmodified tag
 *  ships with, so the bytes match what the Chameleon path writes after reading
 *  the real CC. */
export function webNfcChunkPayload(t: NtagType): number {
  return chunkPayloadForCapacity(ntagFactoryNdefCapacity(t));
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/nfc/type2.ts webapp/test/type2.test.ts
git commit -m "feat(webapp): add factory NDEF capacity for readers that cannot read the CC"
```

---

### Task 3: The `NdefIO` seam and its fake

**Files:**
- Create: `src/transport/ndef-io.ts`, `test/fake-ndef-io.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface NdefRecordInit { recordType: string; mediaType?: string; data?: Uint8Array }
  export interface NdefReadRecord { recordType: string; mediaType?: string; data?: Uint8Array }
  export interface NdefReading { serialNumber: string; records: NdefReadRecord[] }
  export interface NdefIO {
    awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading>;
    write(records: NdefRecordInit[]): Promise<void>;
    stop(): void;
  }
  export function uidFromSerialNumber(serial: string): Uint8Array;
  ```

- [ ] **Step 1: Write the failing test**

Create `test/fake-ndef-io.ts` **and** a small test for the UID parser. Append to a new `test/web-nfc-transport.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { uidFromSerialNumber } from '../src/transport/ndef-io.js';

test('uidFromSerialNumber parses the colon-separated hex Chrome reports', () => {
  assert.deepEqual(
    Array.from(uidFromSerialNumber('04:7b:cd:a4:82:26:81')),
    [0x04, 0x7b, 0xcd, 0xa4, 0x82, 0x26, 0x81],
  );
});

test('uidFromSerialNumber tolerates upper case and an empty serial', () => {
  assert.deepEqual(Array.from(uidFromSerialNumber('AB:CD')), [0xab, 0xcd]);
  assert.deepEqual(Array.from(uidFromSerialNumber('')), []);
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — cannot find `../src/transport/ndef-io.js`.

- [ ] **Step 3: Write the seam**

Create `src/transport/ndef-io.ts`:

```ts
/**
 * Seam over the Web NFC API. `NDEFReader` exists only in Chrome on Android, and
 * `src/` must import cleanly under `node --test`, so nothing here touches a
 * browser global — the real implementation lives in app/ui/browser-ndef-io.ts.
 */

export interface NdefRecordInit {
  recordType: string;
  mediaType?: string;
  data?: Uint8Array;
}

export interface NdefReadRecord {
  recordType: string;
  mediaType?: string;
  data?: Uint8Array;
}

export interface NdefReading {
  /** Colon-separated hex, e.g. "04:7b:cd:a4:82:26:81". May be empty. */
  serialNumber: string;
  records: NdefReadRecord[];
}

export interface NdefIO {
  /** Resolves with the first tag presented. Rejects on timeout or abort. */
  awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading>;
  /** Write to the tag currently in the field. */
  write(records: NdefRecordInit[]): Promise<void>;
  /** Stop any active scan. */
  stop(): void;
}

/** Chrome reports the UID as colon-separated hex; the rest of the app uses bytes. */
export function uidFromSerialNumber(serial: string): Uint8Array {
  if (serial === '') return new Uint8Array(0);
  return Uint8Array.from(serial.split(':').map((h) => parseInt(h, 16)));
}
```

- [ ] **Step 4: Write the fake**

Create `test/fake-ndef-io.ts`:

```ts
import { TagTimeoutError } from '../src/transport/transport.js';
import type { NdefIO, NdefReading, NdefRecordInit } from '../src/transport/ndef-io.js';

/**
 * In-memory Web NFC. Queue readings with `tap()`; `write()` replaces the
 * records of the tag most recently presented, mirroring how Chrome writes to
 * the tag still in the field.
 */
export class FakeNdefIO implements NdefIO {
  private queue: NdefReading[] = [];
  private current: NdefReading | null = null;
  writes: NdefRecordInit[][] = [];
  failNextWrite: Error | null = null;

  tap(serialNumber: string, records: NdefReading['records'] = []): void {
    this.queue.push({ serialNumber, records });
  }

  async awaitReading(): Promise<NdefReading> {
    const next = this.queue.shift();
    if (next === undefined) throw new TagTimeoutError('no tag presented');
    this.current = next;
    return next;
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    if (this.failNextWrite !== null) {
      const err = this.failNextWrite;
      this.failNextWrite = null;
      throw err;
    }
    this.writes.push(records);
    if (this.current !== null) {
      this.current.records = records.map((r) => ({
        recordType: r.recordType,
        mediaType: r.mediaType,
        data: r.data,
      }));
      // Re-present the same tag so a read-back or contract re-tap sees it.
      this.queue.unshift(this.current);
    }
  }

  stop(): void {
    this.queue = [];
  }
}
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, 2 new tests.

- [ ] **Step 6: Commit**

```bash
git add webapp/src/transport/ndef-io.ts webapp/test/fake-ndef-io.ts webapp/test/web-nfc-transport.test.ts
git commit -m "feat(webapp): add the NdefIO seam for Web NFC"
```

---

### Task 4: `WebNfcTransport`

**Files:**
- Create: `src/transport/web-nfc-transport.ts`
- Modify: `test/web-nfc-transport.test.ts`

**Interfaces:**
- Consumes: `NdefIO`, `NdefReading`, `uidFromSerialNumber` (Task 3); `webNfcChunkPayload`, `ntagFactoryNdefCapacity` (Task 2); `encodeNdefMime`, `decodeNdefMime`, `NdefFormatError` from `src/nfc/ndef.js`; `NtagType` from `src/nfc/type2.js`; `Transport`, `PresentedTag`, `TagTimeoutError`, `NfarFormatError`.
- Produces: `class WebNfcTransport implements Transport`, constructed as `new WebNfcTransport(io, NtagType.NTAG215)`.

**The one-tap model:** `awaitTag()` caches the reading; `peekIsNfar()` and `readChunk()` use that cache with no further tap; `writeChunk()` writes to the tag still in the field.

- [ ] **Step 1: Write the failing tests**

Append to `test/web-nfc-transport.test.ts`:

```ts
import { WebNfcTransport } from '../src/transport/web-nfc-transport.js';
import { FakeNdefIO } from './fake-ndef-io.js';
import { NtagType, webNfcChunkPayload } from '../src/nfc/type2.js';
import { runTransportContract } from './transport-contract.js';
import { encodeNdefMime } from '../src/nfc/ndef.js';
import { encodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

function nfarRecords(payloadLen: number) {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 1) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).fill(9),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  };
  const bytes = encodeChunk(c);
  return {
    bytes,
    records: [{
      recordType: 'mime',
      mediaType: 'application/vnd.nfcarchiver.chunk',
      data: bytes,
    }],
  };
}

test('awaitTag reports the UID and the selected type capacity', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  const tag = await t.awaitTag();
  assert.deepEqual(Array.from(tag.uid), [4, 1, 2, 3]);
  assert.equal(tag.maxChunkPayload, webNfcChunkPayload(NtagType.NTAG215));
  assert.equal(tag.maxChunkPayload, 420);
});

test('peekIsNfar uses the cached reading — no second tap', async () => {
  const io = new FakeNdefIO();
  const { records } = nfarRecords(50);
  io.tap('04:01:02:03', records);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);
  // A second tap was never queued; if peek had consumed one this would throw.
  assert.deepEqual(await t.readChunk(), records[0]!.data);
});

test('a blank tag peeks false rather than throwing', async () => {
  const io = new FakeNdefIO();
  io.tap('04:09:09:09', []);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), false);
});

test('a foreign NDEF record peeks false', async () => {
  const io = new FakeNdefIO();
  io.tap('04:09:09:09', [{ recordType: 'text', data: new Uint8Array([1, 2, 3]) }]);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), false);
});

test('writeChunk emits one MIME record with the NFAR media type', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  const { bytes } = nfarRecords(50);
  await t.writeChunk(bytes);
  assert.equal(io.writes.length, 1);
  assert.equal(io.writes[0]!.length, 1);
  assert.equal(io.writes[0]![0]!.mediaType, 'application/vnd.nfcarchiver.chunk');
  assert.deepEqual(io.writes[0]![0]!.data, bytes);
});

test('awaitTag rejects TagTimeoutError when no tag is presented', async () => {
  const t = new WebNfcTransport(new FakeNdefIO(), NtagType.NTAG215);
  await t.connect();
  await assert.rejects(() => t.awaitTag(), TagTimeoutError);
});

runTransportContract('WebNfcTransport+FakeNdefIO', () => {
  const io = new FakeNdefIO();
  const transport = new WebNfcTransport(io, NtagType.NTAG215);
  return {
    transport,
    tap: (uid: Uint8Array) => {
      io.tap(Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join(':'));
    },
  };
}, {
  capacityBytes: ntagFactoryNdefCapacity(NtagType.NTAG215),
  maxChunkPayload: webNfcChunkPayload(NtagType.NTAG215),
});
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — cannot find `../src/transport/web-nfc-transport.js`.

- [ ] **Step 3: Write the transport**

Create `src/transport/web-nfc-transport.ts`:

```ts
/**
 * Transport over the phone's own NFC radio via Web NFC. NDEF only — no raw page
 * access, so no Mifare Classic and no card inspection.
 *
 * Web NFC inverts the Chameleon's model: `write()` IS the tap, rather than an
 * operation on a tag already waited for. To keep one tap per card, awaitTag()
 * caches the reading it received and peek/read serve from that cache; writeChunk
 * then writes to the tag still in the field.
 */
import { encodeNdefMime, decodeNdefMime } from '../nfc/ndef.js';
import { NtagType } from '../nfc/type2.js';
import { ntagFactoryNdefCapacity, webNfcChunkPayload } from '../nfc/type2.js';
import { NfarFormatError } from '../chunk.js';
import type { NdefIO, NdefReading } from './ndef-io.js';
import { uidFromSerialNumber } from './ndef-io.js';
import { CardCapacityError } from '../mifare/card-layout.js';
import { TagTimeoutError, type PresentedTag, type Transport } from './transport.js';

const NFAR_MIME = 'application/vnd.nfcarchiver.chunk';

export class WebNfcTransport implements Transport {
  readonly name = 'web-nfc';
  private current: NdefReading | null = null;

  /** `tagType` is the user's explicit choice: Web NFC exposes no capability
   *  container, so capacity cannot be discovered from the card. */
  constructor(private readonly io: NdefIO, private readonly tagType: NtagType) {}

  async connect(): Promise<void> {
    // Nothing to open: the browser owns the radio. Present for interface parity.
  }

  async disconnect(): Promise<void> {
    this.current = null;
    this.io.stop();
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const reading = await this.io.awaitReading(opts);
    this.current = reading;
    return {
      uid: uidFromSerialNumber(reading.serialNumber),
      capacityBytes: ntagFactoryNdefCapacity(this.tagType),
      maxChunkPayload: webNfcChunkPayload(this.tagType),
    };
  }

  /** The NFAR chunk carried by the cached reading, or null. */
  private cachedChunk(): Uint8Array | null {
    if (this.current === null) return null;
    for (const record of this.current.records) {
      if (record.recordType !== 'mime' || record.mediaType !== NFAR_MIME) continue;
      if (record.data === undefined) continue;
      return record.data;
    }
    return null;
  }

  async peekIsNfar(): Promise<boolean> {
    return this.cachedChunk() !== null;
  }

  async readChunk(): Promise<Uint8Array> {
    const bytes = this.cachedChunk();
    if (bytes === null) throw new NfarFormatError('This tag holds no NFAR NDEF data');
    return bytes;
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const max = webNfcChunkPayload(this.tagType);
    const wrapped = encodeNdefMime(bytes).length;
    if (wrapped > ntagFactoryNdefCapacity(this.tagType)) {
      throw new CardCapacityError(
        `Chunk wraps to ${wrapped} B; ${this.tagType} holds ` +
        `${ntagFactoryNdefCapacity(this.tagType)} B of NDEF (max payload ${max} B)`,
      );
    }
    await this.io.write([{ recordType: 'mime', mediaType: NFAR_MIME, data: bytes }]);
  }
}
```

`decodeNdefMime` is imported for symmetry with the Chameleon transports but is not needed here, because Web NFC hands us parsed records rather than raw TLV bytes — **remove that import** if `tsc` flags it as unused.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, including every contract test.

If a contract test fails, read it before changing the transport: the contract encodes behaviour every transport must share, and `FakeNdefIO`'s re-presentation after a write may need adjusting rather than the transport.

- [ ] **Step 5: Commit**

```bash
git add webapp/src/transport/web-nfc-transport.ts webapp/test/web-nfc-transport.test.ts
git commit -m "feat(webapp): add WebNfcTransport over the NdefIO seam"
```

---

### Task 5: The browser `NdefIO` implementation

**Files:**
- Create: `app/ui/browser-ndef-io.ts`

**Interfaces:**
- Consumes: `NdefIO`, `NdefReading`, `NdefRecordInit` (Task 3); `TagTimeoutError`, `CardCapacityError`.
- Produces: `class BrowserNdefIO implements NdefIO`, `export function webNfcAvailable(): boolean`.

This is the only file touching `NDEFReader`, and it cannot be unit-tested headlessly — keep it as thin as possible so there is nothing in it worth testing.

- [ ] **Step 1: Write it**

Create `app/ui/browser-ndef-io.ts`:

```ts
/**
 * The real Web NFC implementation of NdefIO. Chrome on Android only.
 *
 * Deliberately thin: it exists to keep NDEFReader out of src/ (which must
 * import under node --test) and to translate DOM errors into the app's typed
 * errors. All behaviour worth testing lives in WebNfcTransport.
 */
import type { NdefIO, NdefReading, NdefRecordInit } from '../../src/transport/ndef-io.js';
import { TagTimeoutError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';

export function webNfcAvailable(): boolean {
  return typeof (globalThis as { NDEFReader?: unknown }).NDEFReader === 'function';
}

export class BrowserNdefIO implements NdefIO {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private reader: any = null;
  private scanning: AbortController | null = null;

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    const Ctor = (globalThis as { NDEFReader?: new () => unknown }).NDEFReader;
    if (Ctor === undefined) throw new Error('Web NFC is not available in this browser');
    this.reader ??= new Ctor();

    this.scanning?.abort();
    const ac = new AbortController();
    this.scanning = ac;
    if (opts?.signal) {
      opts.signal.addEventListener('abort', () => ac.abort(), { once: true });
    }

    return new Promise<NdefReading>((resolve, reject) => {
      const timer = opts?.timeoutMs === undefined ? null : setTimeout(() => {
        ac.abort();
        reject(new TagTimeoutError(`No tag presented within ${opts.timeoutMs}ms`));
      }, opts.timeoutMs);

      const r = this.reader as {
        scan(o: { signal: AbortSignal }): Promise<void>;
        onreading: ((e: unknown) => void) | null;
        onreadingerror: ((e: unknown) => void) | null;
      };

      r.onreading = (event: unknown) => {
        if (timer !== null) clearTimeout(timer);
        const e = event as {
          serialNumber: string;
          message: { records: Array<{ recordType: string; mediaType?: string; data?: DataView }> };
        };
        resolve({
          serialNumber: e.serialNumber ?? '',
          records: e.message.records.map((rec) => ({
            recordType: rec.recordType,
            mediaType: rec.mediaType,
            data: rec.data === undefined
              ? undefined
              : new Uint8Array(rec.data.buffer, rec.data.byteOffset, rec.data.byteLength),
          })),
        });
      };
      r.onreadingerror = () => {
        if (timer !== null) clearTimeout(timer);
        reject(new Error('Could not read the tag — hold it still and try again'));
      };
      r.scan({ signal: ac.signal }).catch(reject);
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    const r = this.reader as { write(msg: unknown): Promise<void> } | null;
    if (r === null) throw new Error('Start a scan before writing');
    try {
      await r.write({ records });
    } catch (e) {
      // Chrome reports "does not fit" and several hardware refusals as
      // DOMExceptions. Capacity is the one the user can act on, and Web NFC
      // gives us no way to check it in advance.
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
  }
}
```

- [ ] **Step 2: Verify it compiles and nothing regressed**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS. There are no tests for this file by design; `tsc` is the gate.

- [ ] **Step 3: Commit**

```bash
git add webapp/app/ui/browser-ndef-io.ts
git commit -m "feat(webapp): add the browser Web NFC implementation of NdefIO"
```

---

### Task 6: Reader picker and Disconnect button

**Files:**
- Modify: `app/index.html`, `app/ui/device.ts`, `app/i18n/en.ts` + the six translations, `test/i18n.test.ts`

**Interfaces:**
- Consumes: `WebNfcTransport` (Task 4), `BrowserNdefIO`, `webNfcAvailable` (Task 5).
- Produces: `activeReaderName(): 'chameleon' | 'web-nfc' | null` exported from `app/ui/device.ts`, for the panels in Task 7.

- [ ] **Step 1: Add the markup**

In `app/index.html`, replace the device-bar buttons with:

```html
    <div id="device-bar">
      <button id="connect" data-i18n="connect">Connect Chameleon</button>
      <button id="use-web-nfc" hidden data-i18n="usePhoneNfc">Use phone NFC</button>
      <!-- No data-i18n: this span mirrors live connection state, so device.ts
           owns it and re-renders it on locale change. applyStaticText() would
           overwrite "connected" with the disconnected text. -->
      <span id="conn">disconnected</span>
      <button id="inspect" disabled data-i18n="inspectCard">Inspect card</button>
      <button id="disconnect" disabled data-i18n="disconnect">Disconnect</button>
      <pre id="device-status"></pre>
    </div>
```

`#use-web-nfc` starts `hidden`; `device.ts` unhides it when `webNfcAvailable()`.

- [ ] **Step 2: Add the strings to all seven catalogues**

In `app/i18n/en.ts`:

```ts
  usePhoneNfc: 'Use phone NFC',
  disconnect: 'Disconnect',
  connectedPhoneNfc: 'Using phone NFC.',
  inspectNeedsChameleon: 'Card inspection needs a Chameleon — phone NFC has no raw card access.',
  autoDetectNeedsChameleon: 'Pick a tag type: phone NFC cannot detect card capacity.',
```

Add all five to `ru.ts`, `uk.ts`, `be.ts`, `pl.ts`, `tr.ts`, `ka.ts`. `tsc` will not compile until every locale has them — that is the gate. Do not translate "Chameleon" or "NFC".

- [ ] **Step 3: Verify the catalogues**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS. `test/i18n.test.ts`'s parity tests fail if any locale is missing a key, and the markup-drift test fails if `data-i18n="usePhoneNfc"` or `"disconnect"` does not resolve.

- [ ] **Step 4: Wire the picker and Disconnect in `device.ts`**

`device.ts` currently owns `ultra`, `transport`, `connected`, `readerBusy`, `listeners` and `renderConn()`. Extend it:

```ts
import { WebNfcTransport } from '../../src/transport/web-nfc-transport.js';
import { BrowserNdefIO, webNfcAvailable } from './browser-ndef-io.js';
import { NtagType } from '../../src/nfc/type2.js';

let reader: 'chameleon' | 'web-nfc' | null = null;

export function activeReaderName(): 'chameleon' | 'web-nfc' | null {
  return reader;
}
```

- set `reader = 'chameleon'` on a successful Chameleon connect and `null` on its `disconnected` event
- in `initDeviceBar()`, unhide `#use-web-nfc` when `webNfcAvailable()` returns true
- on `#use-web-nfc` click: build `new WebNfcTransport(new BrowserNdefIO(), selectedNtagType())` where `selectedNtagType()` reads the `#target-tag` select, set `reader = 'web-nfc'`, set `connected = true`, notify listeners, and set the status to `t.connectedPhoneNfc`
- on `#disconnect` click: `await transport?.disconnect()`, clear `transport`/`ultra`, set `reader = null`, `connected = false`, notify listeners, and re-render

Extend `updateInspectButton()` into a single `updateDeviceButtons()` that sets:

```ts
  ($('inspect') as HTMLButtonElement).disabled =
    !connected || readerBusy || reader !== 'chameleon';
  ($('disconnect') as HTMLButtonElement).disabled = !connected || readerBusy;
  ($('inspect') as HTMLButtonElement).title =
    reader === 'web-nfc' ? t.inspectNeedsChameleon : '';
```

Disconnect is disabled while `readerBusy`, reusing the interlock that already gates Inspect during an archive write, scan or inspection. Call `updateDeviceButtons()` everywhere `updateInspectButton()` was called, plus after each reader change.

- [ ] **Step 5: Verify**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/device.ts webapp/app/i18n/ webapp/test/i18n.test.ts
git commit -m "feat(webapp): add a reader picker and a Disconnect button"
```

---

### Task 7: Archive panel under phone NFC

**Files:**
- Modify: `app/ui/archive-panel.ts`

**Interfaces:**
- Consumes: `activeReaderName()` (Task 6); `webNfcChunkPayload`, `NtagType` (Task 2).

Web NFC cannot detect capacity, so "Auto-detect" is meaningless there, and sizing must use the factory-CC payload rather than the raw-memory estimate.

- [ ] **Step 1: Disable Auto-detect under phone NFC**

In `archive-panel.ts`, add:

```ts
function syncTargetTagForReader(): void {
  const sel = $('target-tag') as HTMLSelectElement;
  const auto = sel.querySelector<HTMLOptionElement>('option[value="auto"]')!;
  const webNfc = activeReaderName() === 'web-nfc';
  auto.disabled = webNfc;
  if (webNfc && sel.value === 'auto') sel.value = 'NTAG215';
  $('archive-status').textContent = webNfc ? t.autoDetectNeedsChameleon : '';
}
```

Call it from the existing `onConnectionChange` handler.

- [ ] **Step 2: Size chunks from the factory CC under phone NFC**

`selectedPayloadSize()` currently returns `ntagChunkPayloadSize(type)`, which is based on **raw user memory** and would overflow the CC area — the bug fixed in PR #41. Under Web NFC it must use `webNfcChunkPayload(type)`:

```ts
function selectedPayloadSize(): number {
  const v = ($('target-tag') as HTMLSelectElement).value;
  const webNfc = activeReaderName() === 'web-nfc';
  if (v === 'auto') return CARD_PAYLOAD_SIZE;
  if (v === 'NTAG213') return webNfc ? webNfcChunkPayload(NtagType.NTAG213) : ntagChunkPayloadSize(NtagType.NTAG213);
  if (v === 'NTAG215') return webNfc ? webNfcChunkPayload(NtagType.NTAG215) : ntagChunkPayloadSize(NtagType.NTAG215);
  if (v === 'NTAG216') return webNfc ? webNfcChunkPayload(NtagType.NTAG216) : ntagChunkPayloadSize(NtagType.NTAG216);
  return Number(v);
}
```

The Chameleon path keeps its existing pre-tap estimate because it re-chunks from the real CC on first tap; Web NFC never gets that chance, so it must be right up front.

- [ ] **Step 3: Verify**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/ui/archive-panel.ts
git commit -m "feat(webapp): size chunks from the factory CC when using phone NFC"
```

---

### Task 8: Documentation and production build

**Files:**
- Modify: `webapp/README.md`, `CLAUDE.md`

- [ ] **Step 1: Verify the production build**

```bash
cd webapp && rm -rf dist site && BUILD_SHA=$(git rev-parse HEAD) npm run build:site
```

Expected: `site/ built and verified — nfar-build:<sha>, bundle <N> B`. Note the size delta; it should be small (one transport plus a thin wrapper).

- [ ] **Step 2: Document in `webapp/README.md`**

In the existing style, add a Readers section covering: the two readers and how to pick one; that Web NFC is Chrome-on-Android only; that it cannot do Mifare Classic or card inspection, and why (NDEF-only, no raw access); that capacity comes from the selected tag type because Web NFC exposes no capability container; and that Disconnect is disabled while the reader is busy.

- [ ] **Step 3: Document in `CLAUDE.md`**

Under `## Web App (webapp/)`, add:

> - **Readers:** two transports behind the same `Transport` seam. `AutoTransport` over a Chameleon (Mifare Classic + NTAG, full raw access), and `WebNfcTransport` over the phone's own radio (`app/ui/browser-ndef-io.ts` is the only file touching `NDEFReader`). Web NFC is Chrome-on-Android only, NDEF-only — no Mifare, no card inspector — and exposes no capability container, so chunk size comes from the explicitly selected tag type via `webNfcChunkPayload()` (factory CC: 144/496/872), never the raw-memory estimate.

Update the **Status** line: Web NFC is no longer deferred, leaving only the IndexedDB file manager.

- [ ] **Step 4: Final verification**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add webapp/README.md CLAUDE.md
git commit -m "docs(webapp): document the Web NFC reader and the reader picker"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Device bar picker + Disconnect (busy-gated) | 6 |
| `WebNfcTransport` implementing `Transport` | 4 |
| `NdefIO` seam, browser vs fake | 3, 5 |
| One-tap model (cache the reading) | 4 |
| Capacity from selected tag type | 2, 7 |
| Degraded capabilities (Inspect, Mifare) | 6 |
| Contract suite parameterized, transport enrolled | 1, 4 |
| Overwrite path tested | 4 (`peekIsNfar` true → `ArchiveController` raises `OverwriteRequiredError` unchanged) |
| Hardware validation required | flagged below |

**Placeholder scan:** none. Every code step carries its code; Task 6 Step 4 describes edits to an existing file precisely (which fields, which handlers, which button states) rather than restating the whole file.

**Type consistency:** `NdefIO`'s three methods are identical across Tasks 3, 4 and 5. `NdefReading`/`NdefRecordInit` field names match between the seam, the fake and the browser implementation. `webNfcChunkPayload` / `ntagFactoryNdefCapacity` from Task 2 are consumed under those exact names in Tasks 4 and 7. `runTransportContract`'s new third parameter has the same shape in Tasks 1 and 4. `activeReaderName()` returns the same union in Tasks 6 and 7.

**Correction carried from the spec:** an earlier version of the spec claimed `NtagTransport` was already held to the shared contract suite and that enrolling `WebNfcTransport` was nearly free. Neither was true — the suite hardcoded Mifare capacities and only two transports used it. The spec has been corrected and Task 1 now does the parameterization explicitly, which also enrols `NtagTransport` for the first time.

**Cannot be verified headlessly, and must be validated on an Android phone running Chrome:**

1. **The one-tap assumption** — that `write()` targets the tag already in the field rather than waiting for a fresh tap. If it fails, the fallback is always-two-taps and only `WebNfcTransport` changes.
2. **`BrowserNdefIO` end to end** — the `onreading` event shape, `serialNumber` format, and which `DOMException` names Chrome actually raises on a too-small card. The mapping in Task 5 Step 1 is written from the specification, not from observed behaviour.
