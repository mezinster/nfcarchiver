# Web App Iteration 2 — Mifare Classic Transport + Minimal UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store and restore NFAR chunks on physical Mifare Classic 1K cards through a Chameleon Ultra over Web Bluetooth, wrapped in a minimal localhost browser UI.

**Architecture:** A pure card-layout codec maps one NFAR chunk to the 47 usable data blocks of a 1K card. A reworked `Transport` v2 interface (promise-based `awaitTag`, UID identity, write-then-verify) is implemented by an upgraded `MockTransport` and by a real `ChameleonBleTransport` that talks to a narrow `ChameleonDevice` seam — the real SDK sits behind one adapter file; a `FakeChameleon` behind the same seam drives all hardware-free tests. A DOM-free controller state machine runs both flows; thin DOM glue and an esbuild dev server present them.

**Tech Stack:** TypeScript 5, Node ≥ 22, `node:test`, `chameleon-ultra.js` (MIT, first runtime dep), esbuild (dev dep).

**Spec:** `docs/superpowers/specs/2026-07-27-webapp-mifare-transport-ui-design.md` — its Decisions and Card Layout tables are normative.

## Global Constraints

- Branch: `webapp-mifare-transport` (already checked out, based on `webapp-nfar-core-prototype`).
- Every npm/node command runs under Node LTS: prefix `source ~/.nvm/nvm.sh && nvm use --lts` (never change the nvm default alias). `npm test` = `tsc && node --test 'dist/test/**/*.test.js'`.
- **Dependency fence:** the core (`crc32`, `chunk`, `chunker`, `crypto`, `gzip`, `pipeline`, `mifare/card-layout`) stays dependency-free. `chameleon-ultra.js` may be imported ONLY in `webapp/src/transport/sdk-chameleon-device.ts` and `webapp/app/main.ts`.
- Mifare Classic 1K: 64 blocks × 16 B. Excluded: block 0 and every sector trailer (`block % 4 === 3`). 47 usable data blocks = 752 bytes. `CARD_CAPACITY_BYTES = 752`, `CARD_PAYLOAD_SIZE = 720` (= 752 − 32 NFAR overhead).
- Keys: factory key A `FF FF FF FF FF FF` only this iteration.
- Exactly one NFAR chunk per card. `writeChunk` = write all blocks, then read every block back and byte-compare (`WriteVerifyError` on mismatch).
- All 41 iteration-1 tests keep passing; interop fixtures untouched.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Card layout codec

**Files:**
- Create: `webapp/src/mifare/card-layout.ts`
- Test: `webapp/test/card-layout.test.ts`

**Interfaces:**
- Consumes: `NFAR_MAGIC`, `NFAR_VERSION`, `TOTAL_OVERHEAD`, `NfarFormatError` from `../chunk.js`.
- Produces:
  - `USABLE_BLOCK_INDEXES: readonly number[]` (47 ordered block indexes)
  - `CARD_CAPACITY_BYTES = 752`, `CARD_PAYLOAD_SIZE = 720`, `BLOCK_SIZE = 16`
  - `class CardCapacityError extends Error`
  - `chunkToBlocks(chunkBytes: Uint8Array): { block: number; data: Uint8Array }[]` (throws `CardCapacityError` if `> 752`)
  - `firstBlockIsNfar(block1: Uint8Array): boolean` (magic + version, from ≥ 5 bytes)
  - `nfarTotalLength(header: Uint8Array): number` (needs ≥ 28 bytes; throws `NfarFormatError` if magic/version bad; returns `32 + payloadSize`)
  - `assembleChunkFromBlocks(orderedBlockData: Uint8Array[], totalLength: number): Uint8Array`

- [ ] **Step 1: Write the failing test**

`webapp/test/card-layout.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  USABLE_BLOCK_INDEXES, CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE, BLOCK_SIZE,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks,
  CardCapacityError,
} from '../src/mifare/card-layout.js';
import { encodeChunk, NfarFormatError, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

function chunkOfPayload(n: number): Uint8Array {
  const payload = new Uint8Array(n).map((_, i) => (i * 3) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).map((_, i) => i + 1),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  };
  return encodeChunk(c);
}

test('exactly 47 usable blocks, excluding block 0 and every sector trailer', () => {
  assert.equal(USABLE_BLOCK_INDEXES.length, 47);
  assert.equal(CARD_CAPACITY_BYTES, USABLE_BLOCK_INDEXES.length * BLOCK_SIZE);
  assert.ok(!USABLE_BLOCK_INDEXES.includes(0));
  for (const b of USABLE_BLOCK_INDEXES) assert.notEqual(b % 4, 3, `block ${b} is a sector trailer`);
  assert.deepEqual(USABLE_BLOCK_INDEXES.slice(0, 5), [1, 2, 4, 5, 6]);
  assert.equal(USABLE_BLOCK_INDEXES.at(-1), 62);
});

test('chunkToBlocks maps bytes onto usable blocks in order, zero-padding the last', () => {
  const bytes = chunkOfPayload(20); // 52 total -> ceil(52/16)=4 blocks
  const blocks = chunkToBlocks(bytes);
  assert.equal(blocks.length, 4);
  assert.deepEqual(blocks.map((b) => b.block), [1, 2, 4, 5]);
  assert.ok(blocks.every((b) => b.data.length === 16));
  // reassembling all block data and trimming reproduces the chunk
  const flat = new Uint8Array(blocks.length * 16);
  blocks.forEach((b, i) => flat.set(b.data, i * 16));
  assert.deepEqual(flat.subarray(0, bytes.length), bytes);
  assert.ok(flat.subarray(bytes.length).every((x) => x === 0)); // padding is zero
});

test('a full 720-byte payload fills all 47 blocks; 721 overflows', () => {
  const full = chunkOfPayload(CARD_PAYLOAD_SIZE); // 752 total
  assert.equal(chunkToBlocks(full).length, 47);
  assert.throws(() => chunkToBlocks(chunkOfPayload(CARD_PAYLOAD_SIZE + 1)), CardCapacityError);
});

test('firstBlockIsNfar detects magic + version', () => {
  const bytes = chunkOfPayload(10);
  assert.ok(firstBlockIsNfar(bytes.subarray(0, 16)));
  const notMagic = bytes.slice(0, 16); notMagic[0] = 0x00;
  assert.ok(!firstBlockIsNfar(notMagic));
  const badVer = bytes.slice(0, 16); badVer[4] = 0x02;
  assert.ok(!firstBlockIsNfar(badVer));
});

test('nfarTotalLength reads payloadSize from the header, rejects non-NFAR', () => {
  const bytes = chunkOfPayload(100); // total 132
  assert.equal(nfarTotalLength(bytes.subarray(0, 28)), 132);
  const bad = bytes.slice(0, 28); bad[0] = 0x00;
  assert.throws(() => nfarTotalLength(bad), NfarFormatError);
});

test('assembleChunkFromBlocks concatenates ordered block data and trims to length', () => {
  const bytes = chunkOfPayload(30); // total 62, 4 blocks
  const blocks = chunkToBlocks(bytes).map((b) => b.data);
  assert.deepEqual(assembleChunkFromBlocks(blocks, bytes.length), bytes);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/mifare/card-layout.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/mifare/card-layout.ts`:

```ts
/**
 * Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K card.
 * Layout is raw NFAR-native: serialized chunk bytes are written sequentially
 * across the 47 usable blocks (block 0 and every sector trailer skipped),
 * zero-padding the final block. The NFAR header is self-delimiting, so no
 * per-block framing is added.
 */

import { NFAR_MAGIC, NFAR_VERSION, TOTAL_OVERHEAD, NfarFormatError } from '../chunk.js';

export const BLOCK_SIZE = 16;

export const USABLE_BLOCK_INDEXES: readonly number[] = Object.freeze(
  Array.from({ length: 64 }, (_, b) => b).filter((b) => b !== 0 && b % 4 !== 3),
);

export const CARD_CAPACITY_BYTES = USABLE_BLOCK_INDEXES.length * BLOCK_SIZE; // 752
export const CARD_PAYLOAD_SIZE = CARD_CAPACITY_BYTES - TOTAL_OVERHEAD; // 720

export class CardCapacityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardCapacityError';
  }
}

export function chunkToBlocks(chunkBytes: Uint8Array): { block: number; data: Uint8Array }[] {
  if (chunkBytes.length > CARD_CAPACITY_BYTES) {
    throw new CardCapacityError(
      `Chunk is ${chunkBytes.length} bytes; a Mifare Classic 1K card holds ${CARD_CAPACITY_BYTES}`,
    );
  }
  const blockCount = Math.ceil(chunkBytes.length / BLOCK_SIZE);
  const out: { block: number; data: Uint8Array }[] = [];
  for (let i = 0; i < blockCount; i++) {
    const data = new Uint8Array(BLOCK_SIZE); // zero-filled -> pads the last block
    data.set(chunkBytes.subarray(i * BLOCK_SIZE, (i + 1) * BLOCK_SIZE));
    out.push({ block: USABLE_BLOCK_INDEXES[i]!, data });
  }
  return out;
}

export function firstBlockIsNfar(block1: Uint8Array): boolean {
  if (block1.length < NFAR_MAGIC.length + 1) return false;
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (block1[i] !== NFAR_MAGIC[i]) return false;
  }
  return block1[NFAR_MAGIC.length] === NFAR_VERSION;
}

export function nfarTotalLength(header: Uint8Array): number {
  if (!firstBlockIsNfar(header)) {
    throw new NfarFormatError('Not an NFAR card: magic or version mismatch');
  }
  if (header.length < TOTAL_OVERHEAD) {
    throw new NfarFormatError(`Header too short: need ${TOTAL_OVERHEAD} bytes, got ${header.length}`);
  }
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  const payloadSize = view.getUint16(26); // big-endian, per NFAR header layout
  return TOTAL_OVERHEAD + payloadSize;
}

export function assembleChunkFromBlocks(orderedBlockData: Uint8Array[], totalLength: number): Uint8Array {
  const flat = new Uint8Array(orderedBlockData.length * BLOCK_SIZE);
  orderedBlockData.forEach((b, i) => flat.set(b, i * BLOCK_SIZE));
  return flat.slice(0, totalLength);
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (41 iteration-1 tests + 6 new = 47 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/mifare/card-layout.ts webapp/test/card-layout.test.ts
git commit -m "feat(webapp): Mifare Classic card-layout codec for NFAR chunks"
```

---

### Task 2: Transport v2 interface, typed errors, ChameleonDevice seam, reworked MockTransport

**Files:**
- Modify (rewrite): `webapp/src/transport/transport.ts`
- Modify (rewrite): `webapp/src/transport/mock-transport.ts`
- Create: `webapp/src/transport/chameleon-device.ts`
- Modify (rewrite): `webapp/test/transport.test.ts`
- Create: `webapp/test/transport-contract.ts`
- Delete: `webapp/src/transport/chameleon-ble.ts` (v1 stub), `webapp/test/chameleon-ble.test.ts`

**Interfaces:**
- Consumes: `CARD_CAPACITY_BYTES`, `firstBlockIsNfar` (Task 1); `NfarFormatError` from `../chunk.js`; `toHex`/`fromHex` from `../../test/hex.js` (tests only).
- Produces:
  - `interface PresentedTag { uid: Uint8Array; capacityBytes: number }`
  - `interface Transport { name; connect(); disconnect(); awaitTag(opts?): Promise<PresentedTag>; peekIsNfar(): Promise<boolean>; readChunk(): Promise<Uint8Array>; writeChunk(bytes): Promise<void> }` with `awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal })`
  - `class CardAuthError`, `class WriteVerifyError`, `class TagTimeoutError` (all `extends Error`)
  - `interface ChameleonDevice { isConnected(): boolean; connect(): Promise<void>; disconnect(): Promise<void>; scanTag(): Promise<Uint8Array | null>; readBlock(block: number, key: Uint8Array): Promise<Uint8Array>; writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> }`
  - `const FACTORY_KEY_A: Uint8Array`
  - `class MockTransport implements Transport` with test helper `enqueueTag(uid: Uint8Array, chunkBytes?: Uint8Array): void`
  - `runTransportContract(name: string, makeBlank: () => { transport: Transport; tapUid: (uid: Uint8Array) => void })` in `transport-contract.ts`

- [ ] **Step 1: Remove the v1 stub and its test**

```bash
cd /home/mezinster/nfcarchiver && git rm webapp/src/transport/chameleon-ble.ts webapp/test/chameleon-ble.test.ts
```

Expected: both files staged for deletion. (They are replaced by the v2 real transport in Task 3.)

- [ ] **Step 2: Write the ChameleonDevice seam**

`webapp/src/transport/chameleon-device.ts`:

```ts
/**
 * Narrow structural seam over the Chameleon Ultra SDK. ChameleonBleTransport
 * depends only on this. The real SDK is wrapped by SdkChameleonDevice
 * (Task 5, the only file importing chameleon-ultra.js); FakeChameleon
 * implements it for tests (Task 3).
 */
export interface ChameleonDevice {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** UID of a tag currently in the field, or null if none. */
  scanTag(): Promise<Uint8Array | null>;
  /** Read a 16-byte block, authenticating with key A. */
  readBlock(block: number, key: Uint8Array): Promise<Uint8Array>;
  /** Write a 16-byte block, authenticating with key A. */
  writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void>;
}

export const FACTORY_KEY_A = new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
```

- [ ] **Step 3: Write the Transport v2 interface and typed errors**

`webapp/src/transport/transport.ts` (replace entire file):

```ts
/**
 * A Transport moves one serialized NFAR chunk to/from the physical card
 * currently presented to a reader. v2: promise-based tag arrival, UID identity,
 * and write-then-verify semantics in writeChunk implementations.
 */

export interface PresentedTag {
  uid: Uint8Array;
  capacityBytes: number;
}

export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Resolves when a tag enters the field. Rejects TagTimeoutError or AbortError. */
  awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag>;
  /** Cheap check: read only the first block and test for NFAR magic+version. */
  peekIsNfar(): Promise<boolean>;
  /** Read the chunk from the current tag. Throws NfarFormatError on a non-NFAR card. */
  readChunk(): Promise<Uint8Array>;
  /** Write the chunk to the current tag, then read back and verify. */
  writeChunk(bytes: Uint8Array): Promise<void>;
}

export class CardAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardAuthError';
  }
}

export class WriteVerifyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WriteVerifyError';
  }
}

export class TagTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TagTimeoutError';
  }
}
```

- [ ] **Step 4: Write the reworked MockTransport**

`webapp/src/transport/mock-transport.ts` (replace entire file):

```ts
import { NfarFormatError } from '../chunk.js';
import { CARD_CAPACITY_BYTES, CardCapacityError, firstBlockIsNfar } from '../mifare/card-layout.js';
import { TagTimeoutError, type PresentedTag, type Transport } from './transport.js';

function toHexKey(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * In-memory Transport double. Tests script a sequence of taps with enqueueTag;
 * each awaitTag presents the next one. Card contents are keyed by UID, so
 * re-enqueuing the same UID presents the same (already-written) card.
 */
export class MockTransport implements Transport {
  readonly name = 'mock';
  private readonly queue: string[] = [];
  private readonly cards = new Map<string, Uint8Array>();
  private active: string | null = null;

  /** Present `uid` on the next awaitTag; optionally pre-load its stored chunk bytes. */
  enqueueTag(uid: Uint8Array, chunkBytes?: Uint8Array): void {
    const key = toHexKey(uid);
    this.queue.push(key);
    if (chunkBytes) this.cards.set(key, chunkBytes.slice());
  }

  async connect(): Promise<void> {}
  async disconnect(): Promise<void> {}

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    const next = this.queue.shift();
    if (next === undefined) {
      throw new TagTimeoutError(`No tag presented within ${opts?.timeoutMs ?? 0}ms`);
    }
    this.active = next;
    return { uid: Uint8Array.from(next.match(/../g)!.map((h) => parseInt(h, 16))), capacityBytes: CARD_CAPACITY_BYTES };
  }

  private activeBytes(): Uint8Array | undefined {
    return this.active === null ? undefined : this.cards.get(this.active);
  }

  async peekIsNfar(): Promise<boolean> {
    const b = this.activeBytes();
    return b !== undefined && b.length >= 16 && firstBlockIsNfar(b.subarray(0, 16));
  }

  async readChunk(): Promise<Uint8Array> {
    const b = this.activeBytes();
    if (b === undefined || !firstBlockIsNfar(b.subarray(0, 16))) {
      throw new NfarFormatError('Current card contains no NFAR chunk');
    }
    return b.slice();
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    if (this.active === null) throw new TagTimeoutError('No active tag to write');
    if (bytes.length > CARD_CAPACITY_BYTES) {
      throw new CardCapacityError(`Chunk ${bytes.length} B exceeds card capacity ${CARD_CAPACITY_BYTES} B`);
    }
    this.cards.set(this.active, bytes.slice());
  }
}
```

- [ ] **Step 5: Write the shared contract harness and the failing MockTransport test**

`webapp/test/transport-contract.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { encodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import type { Transport } from '../src/transport/transport.js';
import { toHex } from './hex.js';

function chunkBytes(payloadLen: number, archiveByte = 9): Uint8Array {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 1) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).fill(archiveByte),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  };
  return encodeChunk(c);
}

/**
 * Behaviours every Transport must satisfy, expressed only through the interface.
 * `tap(uid)` schedules the given UID as the next tag the transport will present.
 */
export function runTransportContract(
  name: string,
  make: () => { transport: Transport; tap: (uid: Uint8Array) => void },
): void {
  const uidA = new Uint8Array([0xa1, 0xa2, 0xa3, 0xa4]);

  test(`${name}: awaitTag returns uid + 752-byte capacity`, async () => {
    const { transport, tap } = make();
    await transport.connect();
    tap(uidA);
    const tag = await transport.awaitTag({ timeoutMs: 1000 });
    assert.equal(toHex(tag.uid), toHex(uidA));
    assert.equal(tag.capacityBytes, CARD_CAPACITY_BYTES);
  });

  test(`${name}: blank card peeks non-NFAR; write then re-tap reads it back`, async () => {
    const { transport, tap } = make();
    await transport.connect();
    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    assert.equal(await transport.peekIsNfar(), false);

    const bytes = chunkBytes(200);
    await transport.writeChunk(bytes);

    tap(uidA); // same card back in the field
    await transport.awaitTag({ timeoutMs: 1000 });
    assert.equal(await transport.peekIsNfar(), true);
    assert.deepEqual(await transport.readChunk(), bytes);
  });

  test(`${name}: a full 720-byte payload round-trips; oversize is rejected`, async () => {
    const { transport, tap } = make();
    await transport.connect();
    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    const full = chunkBytes(CARD_PAYLOAD_SIZE);
    await transport.writeChunk(full);
    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    assert.deepEqual(await transport.readChunk(), full);

    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    await assert.rejects(() => transport.writeChunk(new Uint8Array(CARD_CAPACITY_BYTES + 1)), CardCapacityError);
  });

  test(`${name}: awaitTag with no tag rejects TagTimeoutError`, async () => {
    const { transport } = make();
    await transport.connect();
    await assert.rejects(() => transport.awaitTag({ timeoutMs: 20 }), /No tag|timeout/i);
  });
}
```

`webapp/test/transport.test.ts` (replace entire file):

```ts
import { MockTransport } from '../src/transport/mock-transport.js';
import { runTransportContract } from './transport-contract.js';

runTransportContract('MockTransport', () => {
  const transport = new MockTransport();
  return { transport, tap: (uid) => transport.enqueueTag(uid) };
});
```

- [ ] **Step 6: Run test to verify it fails, then compiles green**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected first run while files are incomplete: FAIL (module/type errors). After Steps 2-5 are in place: PASS. Total 47 + 4 = 51 tests.

- [ ] **Step 7: Commit**

```bash
git add webapp/src/transport/transport.ts webapp/src/transport/mock-transport.ts webapp/src/transport/chameleon-device.ts webapp/test/transport.test.ts webapp/test/transport-contract.ts
git commit -m "feat(webapp): Transport v2 interface, ChameleonDevice seam, reworked MockTransport"
```

---

### Task 3: ChameleonBleTransport + FakeChameleon

**Files:**
- Create: `webapp/src/transport/chameleon-ble.ts`
- Create: `webapp/test/fake-chameleon.ts`
- Test: `webapp/test/chameleon-ble.test.ts`

**Interfaces:**
- Consumes: `ChameleonDevice`, `FACTORY_KEY_A` (Task 2); `Transport`, `PresentedTag`, `CardAuthError`, `WriteVerifyError`, `TagTimeoutError` (Task 2); `USABLE_BLOCK_INDEXES`, `BLOCK_SIZE`, `CARD_CAPACITY_BYTES`, `chunkToBlocks`, `firstBlockIsNfar`, `nfarTotalLength`, `assembleChunkFromBlocks` (Task 1); `NfarFormatError` (`../chunk.js`).
- Produces:
  - `class ChameleonBleTransport implements Transport` — constructor `(device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number })`
  - `class FakeChameleon implements ChameleonDevice` (in `test/fake-chameleon.ts`) with helpers: `place(uid: Uint8Array): void`, `remove(): void`, `defineCard(uid: Uint8Array, opts?: { keyA?: Uint8Array }): void`, `corruptNextWrite(): void`, `blockOf(uid: Uint8Array, block: number): Uint8Array`

- [ ] **Step 1: Write the FakeChameleon test double**

`webapp/test/fake-chameleon.ts`:

```ts
import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError } from '../src/transport/transport.js';

function hex(u: Uint8Array): string {
  return Array.from(u, (b) => b.toString(16).padStart(2, '0')).join('');
}
function keysEqual(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

interface Card { image: Uint8Array; keyA: Uint8Array }

/** In-memory Chameleon Ultra over simulated 1K card images (64 x 16 bytes). */
export class FakeChameleon implements ChameleonDevice {
  private connected = false;
  private field: string | null = null;
  private corruptNext = false;
  private readonly cards = new Map<string, Card>();

  defineCard(uid: Uint8Array, opts?: { keyA?: Uint8Array }): void {
    this.cards.set(hex(uid), { image: new Uint8Array(64 * 16), keyA: opts?.keyA ?? FACTORY_KEY_A });
  }
  place(uid: Uint8Array): void {
    const key = hex(uid);
    if (!this.cards.has(key)) this.defineCard(uid);
    this.field = key;
  }
  remove(): void {
    this.field = null;
  }
  corruptNextWrite(): void {
    this.corruptNext = true;
  }
  blockOf(uid: Uint8Array, block: number): Uint8Array {
    return this.cards.get(hex(uid))!.image.slice(block * 16, block * 16 + 16);
  }

  isConnected(): boolean {
    return this.connected;
  }
  async connect(): Promise<void> {
    this.connected = true;
  }
  async disconnect(): Promise<void> {
    this.connected = false;
  }
  async scanTag(): Promise<Uint8Array | null> {
    if (this.field === null) return null;
    return Uint8Array.from(this.field.match(/../g)!.map((h) => parseInt(h, 16)));
  }

  private current(): Card {
    if (this.field === null) throw new CardAuthError('No card in field');
    return this.cards.get(this.field)!;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    const card = this.current();
    if (!keysEqual(key, card.keyA)) throw new CardAuthError(`Auth failed on block ${block}`);
    return card.image.slice(block * 16, block * 16 + 16);
  }

  async writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> {
    const card = this.current();
    if (!keysEqual(key, card.keyA)) throw new CardAuthError(`Auth failed on block ${block}`);
    const toWrite = data.slice(0, 16);
    if (this.corruptNext) {
      this.corruptNext = false;
      toWrite[0] ^= 0xff; // flip a bit so read-back verification fails
    }
    card.image.set(toWrite, block * 16);
  }
}
```

- [ ] **Step 2: Write the failing ChameleonBleTransport test**

`webapp/test/chameleon-ble.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { runTransportContract } from './transport-contract.js';
import { encodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { USABLE_BLOCK_INDEXES } from '../src/mifare/card-layout.js';

function chunkBytes(payloadLen: number): Uint8Array {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 5) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).fill(7), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  };
  return encodeChunk(c);
}

runTransportContract('ChameleonBleTransport+FakeChameleon', () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  return { transport, tap: (uid) => device.place(uid) };
});

test('connect delegates to the device; awaitTag polls scanTag', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  assert.ok(device.isConnected());
  const uid = new Uint8Array([1, 2, 3, 4]);
  setTimeout(() => device.place(uid), 5); // tag arrives after a couple polls
  const tag = await transport.awaitTag();
  assert.deepEqual(tag.uid, uid);
});

test('awaitTag honors AbortSignal', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 5, defaultTimeoutMs: 1000 });
  await transport.connect();
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 10);
  await assert.rejects(() => transport.awaitTag({ signal: ac.signal }), (e: Error) => e.name === 'AbortError');
});

test('writeChunk writes only usable blocks and skips trailers/block 0', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  const uid = new Uint8Array([9, 9, 9, 9]);
  device.place(uid);
  await transport.awaitTag();
  const bytes = chunkBytes(40); // 72 total -> 5 blocks: 1,2,4,5,6
  await transport.writeChunk(bytes);
  // block 0 and trailer block 3 stay zero
  assert.ok(device.blockOf(uid, 0).every((b) => b === 0));
  assert.ok(device.blockOf(uid, 3).every((b) => b === 0));
  // first usable block holds the NFAR magic
  assert.deepEqual(device.blockOf(uid, USABLE_BLOCK_INDEXES[0]!).subarray(0, 4), bytes.subarray(0, 4));
});

test('write-then-verify catches a corrupted block', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  device.place(new Uint8Array([4, 4, 4, 4]));
  await transport.awaitTag();
  device.corruptNextWrite();
  await assert.rejects(() => transport.writeChunk(chunkBytes(30)), WriteVerifyError);
});

test('non-factory-key card surfaces CardAuthError', async () => {
  const device = new FakeChameleon();
  const uid = new Uint8Array([5, 5, 5, 5]);
  device.defineCard(uid, { keyA: new Uint8Array([1, 2, 3, 4, 5, 6]) });
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  device.place(uid);
  await transport.awaitTag();
  await assert.rejects(() => transport.writeChunk(chunkBytes(20)), CardAuthError);
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/chameleon-ble.js'.

- [ ] **Step 4: Write the implementation**

`webapp/src/transport/chameleon-ble.ts`:

```ts
/**
 * Real Transport over a Chameleon Ultra reading/writing physical Mifare Classic
 * 1K cards. Talks only to the ChameleonDevice seam, so it is fully testable
 * against FakeChameleon; the actual SDK is wired in via SdkChameleonDevice.
 */

import { NfarFormatError } from '../chunk.js';
import {
  BLOCK_SIZE, CARD_CAPACITY_BYTES, USABLE_BLOCK_INDEXES,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks,
} from '../mifare/card-layout.js';
import { FACTORY_KEY_A, type ChameleonDevice } from './chameleon-device.js';
import { TagTimeoutError, WriteVerifyError, type PresentedTag, type Transport } from './transport.js';

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class ChameleonBleTransport implements Transport {
  readonly name = 'chameleon-ble';
  private readonly pollMs: number;
  private readonly defaultTimeoutMs: number;

  constructor(private readonly device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number }) {
    this.pollMs = opts?.pollMs ?? 300;
    this.defaultTimeoutMs = opts?.defaultTimeoutMs ?? 20000;
  }

  async connect(): Promise<void> {
    if (!this.device.isConnected()) await this.device.connect();
  }

  async disconnect(): Promise<void> {
    if (this.device.isConnected()) await this.device.disconnect();
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const timeoutMs = opts?.timeoutMs ?? this.defaultTimeoutMs;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const uid = await this.device.scanTag();
      if (uid !== null) return { uid, capacityBytes: CARD_CAPACITY_BYTES };
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  private readUsable(i: number): Promise<Uint8Array> {
    return this.device.readBlock(USABLE_BLOCK_INDEXES[i]!, FACTORY_KEY_A);
  }

  async peekIsNfar(): Promise<boolean> {
    const block1 = await this.readUsable(0);
    return firstBlockIsNfar(block1);
  }

  async readChunk(): Promise<Uint8Array> {
    // First two usable blocks (32 bytes) cover the full NFAR header incl. payloadSize.
    const first = await this.readUsable(0);
    if (!firstBlockIsNfar(first)) throw new NfarFormatError('Current card contains no NFAR chunk');
    const second = await this.readUsable(1);
    const header = new Uint8Array(2 * BLOCK_SIZE);
    header.set(first, 0);
    header.set(second, BLOCK_SIZE);
    const total = nfarTotalLength(header);
    const blockCount = Math.ceil(total / BLOCK_SIZE);
    const blocks: Uint8Array[] = [first, second];
    for (let i = 2; i < blockCount; i++) blocks.push(await this.readUsable(i));
    return assembleChunkFromBlocks(blocks.slice(0, blockCount), total);
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const blocks = chunkToBlocks(bytes); // throws CardCapacityError if > 752
    for (const { block, data } of blocks) await this.device.writeBlock(block, FACTORY_KEY_A, data);
    for (const { block, data } of blocks) {
      const readBack = await this.device.readBlock(block, FACTORY_KEY_A);
      if (!bytesEqual(readBack, data)) {
        throw new WriteVerifyError(`Verification failed on block ${block}: read-back does not match`);
      }
    }
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS. The contract harness adds 4 tests for the new transport plus 5 specific tests = 51 + 9 = 60 total.

- [ ] **Step 6: Commit**

```bash
git add webapp/src/transport/chameleon-ble.ts webapp/test/fake-chameleon.ts webapp/test/chameleon-ble.test.ts
git commit -m "feat(webapp): ChameleonBleTransport over Mifare blocks with FakeChameleon tests"
```

---

### Task 4: End-to-end pipeline over the transport

**Files:**
- Test: `webapp/test/e2e-mifare.test.ts`

**Interfaces:**
- Consumes: `archive`/`restore` (`../src/pipeline.js`), `encodeChunk`/`decodeChunk` (`../src/chunk.js`), `FLAG_COMPRESSED`/`FLAG_ENCRYPTED` (`../src/chunk.js`), `CARD_PAYLOAD_SIZE` (Task 1), `ChameleonBleTransport` (Task 3), `FakeChameleon` (Task 3).
- Produces: no new source; the headline integration proof.

- [ ] **Step 1: Write the end-to-end test**

`webapp/test/e2e-mifare.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archive, restore } from '../src/pipeline.js';
import { encodeChunk, decodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { FakeChameleon } from './fake-chameleon.js';

function compressiblePayload(): Uint8Array {
  const words: string[] = [];
  for (let i = 0; i < 400; i++) words.push(`nfar-card-${i}-payload`);
  return new TextEncoder().encode(words.join(' '));
}

test('archive -> write to fake cards -> shuffled+duplicate scan -> restore', async () => {
  const original = compressiblePayload();
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await transport.connect();

  const chunks = await archive(original, { payloadSize: CARD_PAYLOAD_SIZE, compress: true, password: 'e2e' });
  assert.ok(chunks.length >= 2, `expected multiple cards, got ${chunks.length}`);
  assert.ok(chunks.every((c) => c.flags === (FLAG_COMPRESSED | FLAG_ENCRYPTED)));

  // Write each chunk to its own uniquely-identified card.
  const uids = chunks.map((_, i) => new Uint8Array([0xc0, 0xde, 0x00, i]));
  for (let i = 0; i < chunks.length; i++) {
    device.place(uids[i]!);
    await transport.awaitTag();
    await transport.writeChunk(encodeChunk(chunks[i]!));
  }

  // Restore: scan cards in reverse order, with one accidental re-tap that must be ignored.
  const collected = new Map<number, Chunk>();
  const scanOrder = [...uids].reverse();
  scanOrder.splice(1, 0, scanOrder[0]!); // duplicate the first scanned card
  for (const uid of scanOrder) {
    device.place(uid);
    const tag = await transport.awaitTag();
    const chunk = decodeChunk(await transport.readChunk());
    if (!collected.has(chunk.chunkIndex)) collected.set(chunk.chunkIndex, chunk);
    // UID identity: a repeat scan of an already-collected card is a no-op above
    void tag;
  }

  const restored = await restore([...collected.values()], 'e2e');
  assert.deepEqual(restored, original);
});
```

- [ ] **Step 2: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (60 + 1 = 61 tests). If it fails, the bug is real — a card-layout or transport defect — fix the source, not the test.

- [ ] **Step 3: Commit**

```bash
git add webapp/test/e2e-mifare.test.ts
git commit -m "test(webapp): end-to-end archive/restore over Mifare transport"
```

---

### Task 5: Real SDK adapter (SdkChameleonDevice)

**Files:**
- Create: `webapp/src/transport/sdk-chameleon-device.ts`
- Test: `webapp/test/sdk-chameleon-device.test.ts`
- Modify: `webapp/package.json` (add `chameleon-ultra.js` dependency)

**Interfaces:**
- Consumes: `ChameleonDevice`, `FACTORY_KEY_A` (Task 2).
- Produces:
  - `interface ChameleonUltraSdk` — structural mirror of the SDK methods used (`isConnected(): boolean`, `connect(): Promise<void>`, `disconnect(): Promise<void>`, `cmdHf14aScan(): Promise<{ uid: Uint8Array }[]>`, `cmdMf1ReadBlock(block: number, keyType: number, key: Uint8Array): Promise<Uint8Array>`, `cmdMf1WriteBlock(block: number, keyType: number, key: Uint8Array, data: Uint8Array): Promise<void>`)
  - `const MF1_KEY_A = 0x60` (SDK `Mf1KeyType.KEY_A` numeric value)
  - `class SdkChameleonDevice implements ChameleonDevice` — constructor `(sdk: ChameleonUltraSdk)`

Note: this is the only task that touches the real SDK. Its logic is unit-tested against a hand-written fake `ChameleonUltraSdk`; real-hardware behavior is covered by the manual checklist in Task 7. The SDK returns its own `Buffer` type (a `Uint8Array` subclass), which satisfies `Uint8Array` structurally.

- [ ] **Step 1: Add the dependency**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm install chameleon-ultra.js
```

Expected: `chameleon-ultra.js` appears under `dependencies` in `webapp/package.json`; `package-lock.json` updated.

- [ ] **Step 2: Write the failing test**

`webapp/test/sdk-chameleon-device.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SdkChameleonDevice, MF1_KEY_A, type ChameleonUltraSdk } from '../src/transport/sdk-chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';

function fakeSdk(overrides: Partial<ChameleonUltraSdk> = {}): ChameleonUltraSdk & { calls: unknown[] } {
  const calls: unknown[] = [];
  return {
    calls,
    connected: false,
    isConnected() { return (this as { connected: boolean }).connected; },
    async connect() { (this as { connected: boolean }).connected = true; },
    async disconnect() { (this as { connected: boolean }).connected = false; },
    async cmdHf14aScan() { calls.push(['scan']); return [{ uid: new Uint8Array([1, 2, 3, 4]) }]; },
    async cmdMf1ReadBlock(block, keyType, key) { calls.push(['read', block, keyType, [...key]]); return new Uint8Array(16).fill(block); },
    async cmdMf1WriteBlock(block, keyType, key, data) { calls.push(['write', block, keyType, [...key], [...data]]); },
    ...overrides,
  } as ChameleonUltraSdk & { calls: unknown[] };
}

test('scanTag returns the first tag UID, or null when none present', async () => {
  const dev = new SdkChameleonDevice(fakeSdk());
  assert.deepEqual(await dev.scanTag(), new Uint8Array([1, 2, 3, 4]));
  const empty = new SdkChameleonDevice(fakeSdk({ async cmdHf14aScan() { return []; } }));
  assert.equal(await empty.scanTag(), null);
});

test('readBlock/writeBlock use key type A and pass the key through', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.readBlock(4, FACTORY_KEY_A);
  await dev.writeBlock(4, FACTORY_KEY_A, new Uint8Array(16).fill(9));
  assert.deepEqual(sdk.calls[0], ['read', 4, MF1_KEY_A, [...FACTORY_KEY_A]]);
  assert.deepEqual(sdk.calls[1], ['write', 4, MF1_KEY_A, [...FACTORY_KEY_A], [...new Uint8Array(16).fill(9)]]);
});

test('connect/disconnect delegate to the SDK', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.connect();
  assert.ok(dev.isConnected());
  await dev.disconnect();
  assert.ok(!dev.isConnected());
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/sdk-chameleon-device.js'.

- [ ] **Step 4: Write the implementation**

`webapp/src/transport/sdk-chameleon-device.ts`:

```ts
/**
 * The ONLY file that imports chameleon-ultra.js. Wraps a live ChameleonUltra
 * instance behind the ChameleonDevice seam. Wire-up in the browser:
 *
 *   import { ChameleonUltra } from 'chameleon-ultra.js';
 *   import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
 *   const ultra = new ChameleonUltra();
 *   ultra.use(new WebbleAdapter());
 *   const device = new SdkChameleonDevice(ultra);
 *
 * The real ChameleonUltra satisfies ChameleonUltraSdk structurally; its Buffer
 * return values are Uint8Array subclasses.
 */

import type { ChameleonDevice } from './chameleon-device.js';

/** Mifare Classic key type A. Mirrors the SDK's Mf1KeyType.KEY_A (0x60). */
export const MF1_KEY_A = 0x60;

/** Structural subset of ChameleonUltra used by this adapter. */
export interface ChameleonUltraSdk {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  cmdHf14aScan(): Promise<{ uid: Uint8Array }[]>;
  cmdMf1ReadBlock(block: number, keyType: number, key: Uint8Array): Promise<Uint8Array>;
  cmdMf1WriteBlock(block: number, keyType: number, key: Uint8Array, data: Uint8Array): Promise<void>;
}

export class SdkChameleonDevice implements ChameleonDevice {
  constructor(private readonly sdk: ChameleonUltraSdk) {}

  isConnected(): boolean {
    return this.sdk.isConnected();
  }
  connect(): Promise<void> {
    return this.sdk.connect();
  }
  disconnect(): Promise<void> {
    return this.sdk.disconnect();
  }

  async scanTag(): Promise<Uint8Array | null> {
    const tags = await this.sdk.cmdHf14aScan();
    const first = tags[0];
    return first ? new Uint8Array(first.uid) : null;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    return new Uint8Array(await this.sdk.cmdMf1ReadBlock(block, MF1_KEY_A, key));
  }

  async writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> {
    await this.sdk.cmdMf1WriteBlock(block, MF1_KEY_A, key, data);
  }
}
```

- [ ] **Step 5: Verify the structural type matches the real SDK**

Confirm the import types line up (does not run hardware):

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npx tsc --noEmit && npm test
```

Expected: `tsc` clean and PASS (61 + 3 = 64 tests). If `tsc` reports the real `ChameleonUltra`'s `cmdMf1ReadBlock`/`cmdHf14aScan` signatures differ from `ChameleonUltraSdk` (e.g. a `Mf1KeyType` enum parameter or `Buffer` types), adjust `ChameleonUltraSdk` and the `MF1_KEY_A` value to match the installed package's declarations — the seam exists precisely to absorb that, and only this file changes.

- [ ] **Step 6: Commit**

```bash
git add webapp/package.json webapp/package-lock.json webapp/src/transport/sdk-chameleon-device.ts webapp/test/sdk-chameleon-device.test.ts
git commit -m "feat(webapp): SdkChameleonDevice adapter over chameleon-ultra.js"
```

---

### Task 6: UI controller state machine

**Files:**
- Create: `webapp/app/controller.ts`
- Test: `webapp/test/controller.test.ts`

**Interfaces:**
- Consumes: `archive`/`restore` (`../src/pipeline.js`), `encodeChunk`/`decodeChunk` (`../src/chunk.js`), `FLAG_ENCRYPTED` (`../src/chunk.js`), `CARD_PAYLOAD_SIZE` (Task 1), `Transport`/`PresentedTag` (Task 2), `NfarFormatError` (`../src/chunk.js`).
- Produces:
  - `interface ArchiveRequest { data: Uint8Array; compress: boolean; password?: string }`
  - `interface ArchiveProgress { total: number; written: number; awaiting: number | null; needsOverwriteConfirm: boolean }`
  - `class ArchiveController` — `constructor(transport: Transport)`; `prepare(req): Promise<number>` (returns card count); `writeNextCard(signal?, confirmOverwrite?: boolean): Promise<{ done: boolean; progress: ArchiveProgress }>` (skips a UID already written; requires `confirmOverwrite` when the presented card already holds NFAR data)
  - `class RestoreController` — `constructor(transport: Transport)`; `scanNextCard(signal?): Promise<{ done: boolean; collected: number; total: number | null }>`; `finish(password?: string): Promise<Uint8Array>` (throws `PasswordRequiredError` when encrypted and no password given)
  - `class PasswordRequiredError extends Error`, `class OverwriteRequiredError extends Error`

- [ ] **Step 1: Write the failing test**

`webapp/test/controller.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { encodeChunk } from '../src/chunk.js';
import { ArchiveController, RestoreController, PasswordRequiredError, OverwriteRequiredError } from '../app/controller.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
// Random 2000 bytes: incompressible, so with compress:false it reliably needs
// multiple 720-byte cards (ceil(2000/720) = 3 chunks).
const multiCardData = crypto.getRandomValues(new Uint8Array(2000));

test('archive writes each card once and reports progress', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, compress: false });
  assert.ok(total >= 2, `expected multiple cards, got ${total}`);
  for (let i = 0; i < total; i++) t.enqueueTag(uid(i));
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await ctrl.writeNextCard());
  assert.ok(done);
});

test('archive skips a re-tapped card it already wrote', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, compress: false });
  assert.ok(total >= 2);
  t.enqueueTag(uid(0));
  const first = await ctrl.writeNextCard();
  assert.equal(first.progress.written, 1);
  t.enqueueTag(uid(0)); // same card again -> must be skipped, not double-counted
  const repeat = await ctrl.writeNextCard();
  assert.equal(repeat.progress.written, 1);
  assert.equal(repeat.done, false);
});

test('archive requires explicit confirmation to overwrite an NFAR card', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  await ctrl.prepare({ data: multiCardData, compress: false });
  // A card already carrying NFAR bytes -> peekIsNfar() is true.
  const existingNfar = encodeChunk({
    archiveId: new Uint8Array(16).fill(1), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  t.enqueueTag(uid(7), existingNfar);
  await assert.rejects(() => ctrl.writeNextCard(undefined, false), OverwriteRequiredError);
  t.enqueueTag(uid(7), existingNfar);
  const ok = await ctrl.writeNextCard(undefined, true); // confirmed -> proceeds
  assert.equal(ok.progress.written, 1);
});

test('restore collects chunks and demands a password when encrypted', async () => {
  // Archive to a source transport, capture each card's stored bytes.
  const src = new MockTransport();
  const actrl = new ArchiveController(src);
  const total = await actrl.prepare({ data: multiCardData, compress: false, password: 'pw' });
  assert.ok(total >= 2);
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i));
    await actrl.writeNextCard();
    src.enqueueTag(uid(i));
    await src.awaitTag();
    stored.push(await src.readChunk());
  }

  // Restore from a fresh transport preloaded with those cards.
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  for (let i = 0; i < total; i++) rt.enqueueTag(uid(i), stored[i]!);
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await rctrl.scanNextCard());
  assert.ok(done);
  await assert.rejects(() => rctrl.finish(), PasswordRequiredError);
  assert.deepEqual(await rctrl.finish('pw'), multiCardData);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../app/controller.js'.

- [ ] **Step 3: Write the implementation**

`webapp/app/controller.ts`:

```ts
/**
 * DOM-free state machines for the archive and restore flows. The UI glue
 * (main.ts) drives these and renders their progress; they touch only a
 * Transport, so they are unit-tested against MockTransport.
 */

import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { NfarFormatError } from '../src/chunk.js';
import type { Transport } from '../src/transport/transport.js';

export interface ArchiveRequest {
  data: Uint8Array;
  compress: boolean;
  password?: string;
}

export interface ArchiveProgress {
  total: number;
  written: number;
  awaiting: number | null;
  needsOverwriteConfirm: boolean;
}

export class OverwriteRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OverwriteRequiredError';
  }
}

export class PasswordRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PasswordRequiredError';
  }
}

function uidHex(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

export class ArchiveController {
  private chunks: Chunk[] = [];
  private written = 0;
  private readonly writtenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async prepare(req: ArchiveRequest): Promise<number> {
    this.chunks = await archive(req.data, {
      payloadSize: CARD_PAYLOAD_SIZE,
      compress: req.compress,
      password: req.password,
    });
    this.written = 0;
    this.writtenUids.clear();
    return this.chunks.length;
  }

  private progress(awaiting: number | null, needsOverwriteConfirm: boolean): ArchiveProgress {
    return { total: this.chunks.length, written: this.written, awaiting, needsOverwriteConfirm };
  }

  /**
   * Present the next card and write the next unwritten chunk to it.
   * A card whose UID was already written is skipped (returns not-done, no write).
   * If the presented card already holds NFAR data and confirmOverwrite is not
   * true, throws OverwriteRequiredError without writing.
   */
  async writeNextCard(signal?: AbortSignal, confirmOverwrite = false): Promise<{ done: boolean; progress: ArchiveProgress }> {
    if (this.written >= this.chunks.length) return { done: true, progress: this.progress(null, false) };
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (this.writtenUids.has(key)) {
      return { done: false, progress: this.progress(this.written, false) };
    }
    if (!confirmOverwrite && (await this.transport.peekIsNfar())) {
      throw new OverwriteRequiredError('This card already holds NFAR data; confirm to overwrite');
    }
    await this.transport.writeChunk(encodeChunk(this.chunks[this.written]!));
    this.writtenUids.add(key);
    this.written += 1;
    const done = this.written >= this.chunks.length;
    return { done, progress: this.progress(done ? null : this.written, false) };
  }
}

export class RestoreController {
  private readonly collected = new Map<number, Chunk>();
  private readonly seenUids = new Set<string>();
  private total: number | null = null;
  private encrypted = false;

  constructor(private readonly transport: Transport) {}

  async scanNextCard(signal?: AbortSignal): Promise<{ done: boolean; collected: number; total: number | null }> {
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (!this.seenUids.has(key)) {
      const chunk = decodeChunk(await this.transport.readChunk());
      this.seenUids.add(key);
      if (!this.collected.has(chunk.chunkIndex)) {
        this.collected.set(chunk.chunkIndex, chunk);
        this.total = chunk.totalChunks;
        this.encrypted = (chunk.flags & FLAG_ENCRYPTED) !== 0;
      }
    }
    const done = this.total !== null && this.collected.size >= this.total;
    return { done, collected: this.collected.size, total: this.total };
  }

  async finish(password?: string): Promise<Uint8Array> {
    if (this.encrypted && password === undefined) {
      throw new PasswordRequiredError('This archive is encrypted; a password is required');
    }
    const chunks = [...this.collected.values()];
    return restore(chunks, password);
  }
}

// Re-export so main.ts and tests can surface a clean not-an-NFAR-card message.
export { NfarFormatError };
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (64 + 4 = 68 tests).

- [ ] **Step 5: Commit**

```bash
git add webapp/app/controller.ts webapp/test/controller.test.ts
git commit -m "feat(webapp): DOM-free archive/restore controller state machines"
```

---

### Task 7: UI glue, esbuild dev server, hardware checklist

**Files:**
- Create: `webapp/app/index.html`
- Create: `webapp/app/main.ts`
- Create: `webapp/HARDWARE_TESTING.md`
- Modify: `webapp/package.json` (add `esbuild` dev dep + `app` script), `webapp/.gitignore` (ignore `app/dist`)

**Interfaces:**
- Consumes: `ArchiveController`, `RestoreController`, `OverwriteRequiredError`, `PasswordRequiredError`, `NfarFormatError` (Task 6); `ChameleonBleTransport` (Task 3), `SdkChameleonDevice` (Task 5), `CardCapacityError` (Task 1), `CardAuthError`/`WriteVerifyError`/`TagTimeoutError` (Task 2).
- Produces: no exported API; the browser entry point. `main.ts` contains DOM wiring only (untested per spec).

- [ ] **Step 1: Add esbuild and the app script**

Edit `webapp/package.json`: add to `devDependencies` `"esbuild": "^0.23.0"`, and to `scripts`:

```json
"app": "esbuild app/main.ts --bundle --format=esm --outdir=app/dist --servedir=app --serve=localhost:8000"
```

Then:

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm install
```

Expected: esbuild installed under devDependencies.

- [ ] **Step 2: Ignore the bundle output**

Append to `webapp/.gitignore`:

```
app/dist/
```

- [ ] **Step 3: Write the page**

`webapp/app/index.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NFC Archiver — Web (Mifare Classic)</title>
    <style>
      body { font: 15px/1.5 system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; }
      button { font: inherit; padding: 0.4rem 0.9rem; margin: 0.2rem 0; }
      .row { margin: 0.6rem 0; }
      #status { padding: 0.6rem; border: 1px solid #ccc; border-radius: 6px; min-height: 1.4rem; white-space: pre-wrap; }
      .hidden { display: none; }
    </style>
  </head>
  <body>
    <h1>NFC Archiver — Web</h1>
    <p>Reads/writes NFAR chunks on Mifare Classic 1K cards via a Chameleon Ultra over Web Bluetooth. Chromium browser required; run on the machine with Bluetooth (not inside WSL).</p>
    <div class="row"><button id="connect">Connect Chameleon</button> <span id="conn">disconnected</span></div>
    <fieldset class="row"><legend>Archive a file</legend>
      <input type="file" id="file" />
      <label><input type="checkbox" id="compress" checked /> compress</label>
      <label>password <input type="password" id="apass" placeholder="(optional)" /></label>
      <button id="archive" disabled>Archive to cards</button>
    </fieldset>
    <fieldset class="row"><legend>Restore</legend>
      <label>save as <input type="text" id="fname" value="restored.bin" /></label>
      <button id="restore" disabled>Restore from cards</button>
    </fieldset>
    <div class="row" id="status">Ready.</div>
    <script type="module" src="./dist/main.js"></script>
  </body>
</html>
```

- [ ] **Step 4: Write the DOM glue**

`webapp/app/main.ts`:

```ts
/**
 * DOM glue only: constructs the real transport, drives the controllers, and
 * renders progress/errors. No business logic lives here (that is controller.ts).
 */

import { ChameleonUltra } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice, type ChameleonUltraSdk } from '../src/transport/sdk-chameleon-device.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import {
  ArchiveController, RestoreController, OverwriteRequiredError, PasswordRequiredError, NfarFormatError,
} from './controller.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = $('status');
const setStatus = (msg: string) => { status.textContent = msg; };

function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return 'Card keys are not factory defaults — this card cannot be used.';
  if (e instanceof WriteVerifyError) return 'Write verification failed — move the card closer and retry.';
  if (e instanceof CardCapacityError) return 'A chunk is too large for a 1K card (internal error).';
  if (e instanceof TagTimeoutError) return 'No card detected — tap a card on the reader.';
  if (e instanceof NfarFormatError) return 'This card holds no NFAR archive data.';
  if (e instanceof OverwriteRequiredError) return 'This card already holds data.';
  if (e instanceof PasswordRequiredError) return 'This archive is encrypted — enter a password.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}

let transport: ChameleonBleTransport | null = null;

$('connect').addEventListener('click', async () => {
  try {
    const ultra = new ChameleonUltra();
    ultra.use(new WebbleAdapter());
    transport = new ChameleonBleTransport(new SdkChameleonDevice(ultra as unknown as ChameleonUltraSdk));
    await transport.connect();
    $('conn').textContent = 'connected';
    ($('archive') as HTMLButtonElement).disabled = false;
    ($('restore') as HTMLButtonElement).disabled = false;
    setStatus('Connected. Choose a file to archive, or restore from cards.');
  } catch (e) {
    setStatus(humanError(e));
  }
});

$('archive').addEventListener('click', async () => {
  if (!transport) return;
  const file = ($('file') as HTMLInputElement).files?.[0];
  if (!file) { setStatus('Pick a file first.'); return; }
  const data = new Uint8Array(await file.arrayBuffer());
  const compress = ($('compress') as HTMLInputElement).checked;
  const pass = ($('apass') as HTMLInputElement).value;
  const ctrl = new ArchiveController(transport);
  try {
    const total = await ctrl.prepare({ data, compress, password: pass || undefined });
    setStatus(`Need ${total} card(s). Tap card 1 of ${total}…`);
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.writeNextCard();
        done = res.done;
        setStatus(done ? `Done — wrote ${res.progress.written} card(s).` : `Wrote ${res.progress.written} of ${total}. Tap the next card…`);
      } catch (e) {
        if (e instanceof OverwriteRequiredError) {
          if (confirm('This card already holds data. Overwrite it?')) {
            const res = await ctrl.writeNextCard(undefined, true);
            done = res.done;
            setStatus(done ? `Done — wrote ${res.progress.written} card(s).` : `Wrote ${res.progress.written} of ${total}. Tap the next card…`);
          } else {
            setStatus('Skipped. Tap a different card…');
          }
        } else { throw e; }
      }
    }
  } catch (e) {
    setStatus(humanError(e));
  }
});

$('restore').addEventListener('click', async () => {
  if (!transport) return;
  const ctrl = new RestoreController(transport);
  try {
    setStatus('Tap the first card…');
    let done = false;
    while (!done) {
      const res = await ctrl.scanNextCard();
      done = res.done;
      setStatus(done ? 'All cards scanned. Assembling…' : `Collected ${res.collected}${res.total ? ` of ${res.total}` : ''}. Tap the next card…`);
    }
    let out: Uint8Array;
    try {
      out = await ctrl.finish();
    } catch (e) {
      if (e instanceof PasswordRequiredError) {
        const pw = prompt('This archive is encrypted. Enter password:') ?? undefined;
        out = await ctrl.finish(pw);
      } else { throw e; }
    }
    const name = ($('fname') as HTMLInputElement).value || 'restored.bin';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([out as BlobPart]));
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
    setStatus(`Restored ${out.length} bytes → ${name}.`);
  } catch (e) {
    setStatus(humanError(e));
  }
});
```

- [ ] **Step 5: Write the hardware checklist**

`webapp/HARDWARE_TESTING.md`:

```markdown
# Hardware Testing — Chameleon Ultra + Mifare Classic 1K

Automated tests cover everything up to a FakeChameleon. These steps validate the
real device and must be run manually on a Chromium browser (Chrome/Edge) on a
machine with Bluetooth. **WSL2 has no Bluetooth** — run the browser on the
Windows host and point it at the WSL dev server URL.

## Setup
1. `cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm run app`
2. Open `http://localhost:8000` (or the WSL host IP:8000 from Windows) in Chrome/Edge.
3. Have a Chameleon Ultra (charged, firmware supporting BLE) and 2 blank
   Mifare Classic 1K cards with factory key A (`FF FF FF FF FF FF`).

## Checklist
- [ ] **BLE pairing (the deferred spike):** Click "Connect Chameleon", pick the
      device, confirm it pairs (PIN default `123456`). Status shows "connected".
      If pairing fails, run `hw settings bleclearbonds` on the device and retry.
- [ ] **Single-block read:** With a card on the reader, the app can scan its UID
      (Restore → "Tap the first card" shows a collected count or a
      no-NFAR-data message on a blank card).
- [ ] **Archive a small file across 2 cards:** Pick a ~1 KB file, compress on,
      Archive; tap card 1 then card 2 when prompted. Confirm "Done".
- [ ] **Overwrite guard:** Archive again to one of the written cards; confirm the
      overwrite prompt appears.
- [ ] **Restore round-trip:** Restore, tap both cards in either order, confirm
      the downloaded file is byte-identical to the original (`sha256sum`).
- [ ] **Encrypted round-trip:** Repeat archive with a password; confirm restore
      prompts for it and rejects a wrong one.
- [ ] **Write-verify:** Pull a card away mid-write; confirm a
      verification/timeout error rather than silent corruption.
```

- [ ] **Step 6: Verify the app bundles and the suite is green**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-bundle-check.js >/dev/null && echo "BUNDLE OK"
```

Expected: 68 tests PASS, then `BUNDLE OK` (proves `main.ts` + the SDK imports bundle without errors). If esbuild reports it cannot resolve `chameleon-ultra.js/plugin/WebbleAdapter`, check the installed package's `exports` map and adjust the import path in `main.ts` to the published subpath (only `main.ts` changes).

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/main.ts webapp/HARDWARE_TESTING.md webapp/package.json webapp/package-lock.json webapp/.gitignore
git commit -m "feat(webapp): minimal browser UI, esbuild dev server, hardware checklist"
```

---

## Completion Criteria

- `npm test` in `webapp/` passes (68 tests) on Node LTS.
- `npx tsc --noEmit` clean; `npx esbuild app/main.ts --bundle` succeeds.
- `chameleon-ultra.js` appears only in `webapp/src/transport/sdk-chameleon-device.ts` and `webapp/app/main.ts`; the core stays dependency-free.
- All 41 iteration-1 tests and both interop fixtures still pass.
- `HARDWARE_TESTING.md` present; real-device validation remains a manual step.
```
