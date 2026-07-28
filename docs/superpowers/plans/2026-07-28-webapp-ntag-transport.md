# NTAG Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read/write NFAR chunks on NTAG213/215/216 via the Chameleon Ultra, in the NDEF format the Android app uses, with the app auto-detecting tag type and routing to the right transport.

**Architecture:** Two pure codecs (NDEF record + Type-2 TLV) wrap the unchanged chunk bytes; an `NtagTransport` writes Type-2 pages over a new raw-transceive seam method; an `AutoTransport` routes by SAK between the Mifare Classic and NTAG transports. Core and controllers are reused; only chunking gains a `payloadSize` parameter.

**Tech Stack:** TypeScript 5, Node ≥ 22 (nvm), esbuild. No new runtime deps.

**Spec:** `docs/superpowers/specs/2026-07-28-webapp-ntag-transport-design.md`.

## Global Constraints

- Branch: `webapp-ntag-transport` (already checked out).
- NDEF MIME record: TNF=media (0x02), type = `application/vnd.nfcarchiver.chunk` (33 bytes), payload = the exact NFAR chunk bytes. Flags: `0xD2` short (payload < 256), `0xC2` long. Payload-length: 1 byte (short) or 4-byte big-endian (long). Match the NFC-Forum NDEF standard byte-for-byte.
- Type-2 TLV: `0x03 <len> <ndef> 0xFE`; `len` = 1 byte if ndef < 255, else `0xFF` + 2-byte big-endian. Written from NTAG page 4.
- NTAG user memory: 213 = 144 B, 215 = 504 B, 216 = 888 B. `GET_VERSION` storage byte (index 6): 213 = `0x0F`, 215 = `0x11`, 216 = `0x13`. Type-2 commands: READ `0x30 <page>` (returns 16 B), WRITE `0xA2 <page> <4B>`, GET_VERSION `0x60`.
- Core/controllers reused; the only controller change is an additive `payloadSize` parameter (replacing the hardcoded `CARD_PAYLOAD_SIZE`/720).
- No new runtime dependencies.
- Every npm/node command runs under Node LTS: prefix `source ~/.nvm/nvm.sh && nvm use --lts` and `rm -rf dist` before `npm test`. `npm test` = `tsc && node --test 'dist/test/**/*.test.js'`.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: NDEF MIME record codec

**Files:**
- Create: `webapp/src/nfc/ndef.ts`
- Test: `webapp/test/ndef.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `NDEF_MIME_TYPE = 'application/vnd.nfcarchiver.chunk'`
  - `class NdefFormatError extends Error`
  - `encodeNdefMime(payload: Uint8Array): Uint8Array`
  - `decodeNdefMime(ndef: Uint8Array): Uint8Array`

- [ ] **Step 1: Write the failing test**

`webapp/test/ndef.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeNdefMime, decodeNdefMime, NdefFormatError, NDEF_MIME_TYPE } from '../src/nfc/ndef.js';
import { toHex } from './hex.js';

const MIME = new TextEncoder().encode(NDEF_MIME_TYPE);

test('short record: flags 0xD2, type-length 33, 1-byte payload length, then type + payload', () => {
  const payload = new Uint8Array([1, 2, 3]);
  const rec = encodeNdefMime(payload);
  assert.equal(rec[0], 0xd2); // MB|ME|SR|TNF=media
  assert.equal(rec[1], 33); // type length
  assert.equal(rec[2], 3); // short payload length
  assert.equal(toHex(rec.subarray(3, 3 + 33)), toHex(MIME));
  assert.deepEqual([...rec.subarray(3 + 33)], [1, 2, 3]);
  assert.deepEqual([...decodeNdefMime(rec)], [1, 2, 3]);
});

test('long record: flags 0xC2 and a 4-byte big-endian payload length for payload >= 256', () => {
  const payload = new Uint8Array(300).map((_, i) => i % 256);
  const rec = encodeNdefMime(payload);
  assert.equal(rec[0], 0xc2);
  assert.equal(rec[1], 33);
  assert.deepEqual([...rec.subarray(2, 6)], [0x00, 0x00, 0x01, 0x2c]); // 300 BE
  assert.equal(toHex(rec.subarray(6, 6 + 33)), toHex(MIME));
  assert.deepEqual([...decodeNdefMime(rec)], [...payload]);
});

test('decode rejects a non-NFAR record and truncated input', () => {
  const wrongType = encodeNdefMime(new Uint8Array([9]));
  wrongType[3] = 0x78; // corrupt the MIME type's first byte
  assert.throws(() => decodeNdefMime(wrongType), NdefFormatError);
  assert.throws(() => decodeNdefMime(new Uint8Array([0xd2, 33, 5, 1, 2])), NdefFormatError);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/nfc/ndef.js'.

- [ ] **Step 3: Write the implementation**

`webapp/src/nfc/ndef.ts`:

```ts
/**
 * NDEF record codec for one NFAR chunk. Produces a single NDEF MIME record
 * (TNF=media, type "application/vnd.nfcarchiver.chunk") wrapping the chunk
 * bytes, byte-identical to what Android's nfc_manager.createMime emits — so a
 * tag written here is readable by the Android app and any NFC phone.
 */

export const NDEF_MIME_TYPE = 'application/vnd.nfcarchiver.chunk';
const MIME_BYTES = new TextEncoder().encode(NDEF_MIME_TYPE);

export class NdefFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NdefFormatError';
  }
}

export function encodeNdefMime(payload: Uint8Array): Uint8Array {
  const short = payload.length < 256;
  const flags = 0x80 | 0x40 | 0x02 | (short ? 0x10 : 0); // MB | ME | TNF(media) | SR?
  const lenBytes = short ? 1 : 4;
  const out = new Uint8Array(2 + lenBytes + MIME_BYTES.length + payload.length);
  let i = 0;
  out[i++] = flags;
  out[i++] = MIME_BYTES.length; // type length (33)
  if (short) {
    out[i++] = payload.length;
  } else {
    out[i++] = (payload.length >>> 24) & 0xff;
    out[i++] = (payload.length >>> 16) & 0xff;
    out[i++] = (payload.length >>> 8) & 0xff;
    out[i++] = payload.length & 0xff;
  }
  out.set(MIME_BYTES, i); i += MIME_BYTES.length;
  out.set(payload, i);
  return out;
}

function mimeEquals(bytes: Uint8Array, start: number): boolean {
  if (start + MIME_BYTES.length > bytes.length) return false;
  for (let k = 0; k < MIME_BYTES.length; k++) if (bytes[start + k] !== MIME_BYTES[k]) return false;
  return true;
}

export function decodeNdefMime(ndef: Uint8Array): Uint8Array {
  if (ndef.length < 3) throw new NdefFormatError('NDEF record too short');
  const flags = ndef[0]!;
  const tnf = flags & 0x07;
  if (tnf !== 0x02) throw new NdefFormatError(`Unexpected TNF ${tnf} (want media)`);
  const short = (flags & 0x10) !== 0;
  const typeLen = ndef[1]!;
  let i = 2;
  let payloadLen: number;
  if (short) {
    payloadLen = ndef[i]!; i += 1;
  } else {
    payloadLen = ((ndef[i]! << 24) | (ndef[i + 1]! << 16) | (ndef[i + 2]! << 8) | ndef[i + 3]!) >>> 0;
    i += 4;
  }
  if (typeLen !== MIME_BYTES.length || !mimeEquals(ndef, i)) {
    throw new NdefFormatError('Not an NFAR NDEF record (MIME type mismatch)');
  }
  i += typeLen;
  if (i + payloadLen > ndef.length) throw new NdefFormatError('NDEF payload runs past end of record');
  return ndef.slice(i, i + payloadLen);
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (87 + 3 = 90 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/nfc/ndef.ts webapp/test/ndef.test.ts
git commit -m "feat(webapp): NDEF MIME record codec (Android-compatible) for NFAR chunks"
```

---

### Task 2: Type-2 TLV codec + NTAG capacities

**Files:**
- Create: `webapp/src/nfc/type2.ts`
- Test: `webapp/test/type2.test.ts`

**Interfaces:**
- Consumes: `NdefFormatError`, `encodeNdefMime` (Task 1); `TOTAL_OVERHEAD` from `../chunk.js`.
- Produces:
  - `wrapType2Tlv(ndef: Uint8Array): Uint8Array`
  - `readType2Ndef(memory: Uint8Array): Uint8Array` (throws `NdefFormatError` if no NDEF TLV before a terminator)
  - `enum NtagType { NTAG213='NTAG213', NTAG215='NTAG215', NTAG216='NTAG216' }`
  - `ntagUserBytes(t: NtagType): number`
  - `detectNtagType(getVersion: Uint8Array): NtagType | null`
  - `ntagChunkPayloadSize(t: NtagType): number` — max NFAR payload per chunk that fits this NTAG once NDEF+TLV-wrapped

- [ ] **Step 1: Write the failing test**

`webapp/test/type2.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  wrapType2Tlv, readType2Ndef, NtagType, ntagUserBytes, detectNtagType, ntagChunkPayloadSize,
} from '../src/nfc/type2.js';
import { encodeNdefMime, NdefFormatError } from '../src/nfc/ndef.js';
import { TOTAL_OVERHEAD } from '../src/chunk.js';

test('short TLV: 0x03, 1-byte length, ndef, 0xFE; round-trips', () => {
  const ndef = new Uint8Array([1, 2, 3, 4]);
  const tlv = wrapType2Tlv(ndef);
  assert.equal(tlv[0], 0x03);
  assert.equal(tlv[1], 4);
  assert.deepEqual([...tlv.subarray(2, 6)], [1, 2, 3, 4]);
  assert.equal(tlv[6], 0xfe);
  assert.deepEqual([...readType2Ndef(tlv)], [1, 2, 3, 4]);
});

test('long TLV: 0x03, 0xFF, 2-byte BE length for ndef >= 255', () => {
  const ndef = new Uint8Array(300).fill(7);
  const tlv = wrapType2Tlv(ndef);
  assert.deepEqual([...tlv.subarray(0, 4)], [0x03, 0xff, 0x01, 0x2c]); // 300 BE
  assert.deepEqual([...readType2Ndef(tlv)], [...ndef]);
});

test('readType2Ndef skips lock/memory TLVs and finds the NDEF TLV', () => {
  const ndef = new Uint8Array([9, 9]);
  // 0x01 (lock) len 2 + two bytes, then the NDEF TLV
  const mem = new Uint8Array([0x01, 0x02, 0xaa, 0xbb, 0x03, 0x02, 9, 9, 0xfe, 0, 0]);
  assert.deepEqual([...readType2Ndef(mem)], [...ndef]);
});

test('readType2Ndef throws when there is no NDEF TLV before the terminator', () => {
  assert.throws(() => readType2Ndef(new Uint8Array([0xfe, 0, 0])), NdefFormatError);
});

test('detectNtagType reads the GET_VERSION storage byte', () => {
  const v = (storage: number) => new Uint8Array([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, storage, 0x03]);
  assert.equal(detectNtagType(v(0x0f)), NtagType.NTAG213);
  assert.equal(detectNtagType(v(0x11)), NtagType.NTAG215);
  assert.equal(detectNtagType(v(0x13)), NtagType.NTAG216);
  assert.equal(detectNtagType(v(0x99)), null);
});

test('ntagChunkPayloadSize is the max payload whose wrapped chunk fits user memory', () => {
  for (const t of [NtagType.NTAG213, NtagType.NTAG215, NtagType.NTAG216]) {
    const p = ntagChunkPayloadSize(t);
    const cap = ntagUserBytes(t);
    // A full chunk of this payload, NDEF+TLV-wrapped, must fit; one more byte must not.
    const wrappedLen = (payload: number) => wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
    assert.ok(wrappedLen(p) <= cap, `${t}: payload ${p} wraps to ${wrappedLen(p)} > ${cap}`);
    assert.ok(wrappedLen(p + 1) > cap, `${t}: payload ${p + 1} should overflow ${cap}`);
    assert.ok(p > 0);
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/nfc/type2.js'.

- [ ] **Step 3: Write the implementation**

`webapp/src/nfc/type2.ts`:

```ts
/**
 * NFC-Forum Type-2 tag helpers: NDEF-message TLV framing (written from page 4),
 * NTAG type detection, and per-type capacity math. Mirrors the Android app's
 * maxPayloadForNdefCapacity so the same data fits the same tags.
 */

import { NdefFormatError, encodeNdefMime } from './ndef.js';
import { TOTAL_OVERHEAD } from '../chunk.js';

export function wrapType2Tlv(ndef: Uint8Array): Uint8Array {
  if (ndef.length < 0xff) {
    const out = new Uint8Array(2 + ndef.length + 1);
    out[0] = 0x03;
    out[1] = ndef.length;
    out.set(ndef, 2);
    out[out.length - 1] = 0xfe;
    return out;
  }
  const out = new Uint8Array(4 + ndef.length + 1);
  out[0] = 0x03;
  out[1] = 0xff;
  out[2] = (ndef.length >>> 8) & 0xff;
  out[3] = ndef.length & 0xff;
  out.set(ndef, 4);
  out[out.length - 1] = 0xfe;
  return out;
}

export function readType2Ndef(memory: Uint8Array): Uint8Array {
  let i = 0;
  while (i < memory.length) {
    const tag = memory[i]!;
    if (tag === 0x00) { i += 1; continue; } // NULL TLV
    if (tag === 0xfe) break; // terminator
    if (i + 1 >= memory.length) break;
    let len = memory[i + 1]!;
    let valueStart = i + 2;
    if (len === 0xff) {
      len = (memory[i + 2]! << 8) | memory[i + 3]!;
      valueStart = i + 4;
    }
    if (tag === 0x03) {
      if (valueStart + len > memory.length) throw new NdefFormatError('NDEF TLV runs past end of tag memory');
      return memory.slice(valueStart, valueStart + len);
    }
    i = valueStart + len; // skip lock (0x01) / memory-control (0x02) / other TLVs
  }
  throw new NdefFormatError('No NDEF TLV found in tag memory');
}

export enum NtagType {
  NTAG213 = 'NTAG213',
  NTAG215 = 'NTAG215',
  NTAG216 = 'NTAG216',
}

const USER_BYTES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 144,
  [NtagType.NTAG215]: 504,
  [NtagType.NTAG216]: 888,
};

export function ntagUserBytes(t: NtagType): number {
  return USER_BYTES[t];
}

export function detectNtagType(getVersion: Uint8Array): NtagType | null {
  const storage = getVersion[6];
  if (storage === 0x0f) return NtagType.NTAG213;
  if (storage === 0x11) return NtagType.NTAG215;
  if (storage === 0x13) return NtagType.NTAG216;
  return null;
}

/** Largest NFAR chunk payload whose NDEF+TLV-wrapped form fits this tag's user memory. */
export function ntagChunkPayloadSize(t: NtagType): number {
  const cap = USER_BYTES[t];
  const wrappedLen = (payload: number): number =>
    wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
  // Search downward from the raw capacity; overhead is < 80 bytes so this is cheap.
  for (let p = cap; p > 0; p--) {
    if (wrappedLen(p) <= cap) return p;
  }
  return 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (90 + 6 = 96 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/nfc/type2.ts webapp/test/type2.test.ts
git commit -m "feat(webapp): Type-2 TLV codec + NTAG capacity/type detection"
```

---

### Task 3: Seam change — scanTag returns {uid, sak} + transceive14a

**Files:**
- Modify: `webapp/src/transport/chameleon-device.ts`, `webapp/src/transport/chameleon-ble.ts`, `webapp/src/transport/sdk-chameleon-device.ts`, `webapp/test/fake-chameleon.ts`, `webapp/test/sdk-chameleon-device.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces (updated `ChameleonDevice`):
  - `scanTag(): Promise<{ uid: Uint8Array; sak: number } | null>` (was `Promise<Uint8Array | null>`)
  - `transceive14a(data: Uint8Array, opts?: { appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean }): Promise<Uint8Array>`
  - `FakeChameleon` gains an optional SAK per placed tag (default `0x08`) and a `transceive14a` that throws `NotImplementedError` for now (NTAG simulation is added in Task 4).

- [ ] **Step 1: Update the seam interface**

`webapp/src/transport/chameleon-device.ts` — replace the interface body:

```ts
export interface ChameleonDevice {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** UID + SAK of a tag in the field, or null if none. SAK 0x08 = Mifare Classic 1K, 0x00 = NTAG/Type-2. */
  scanTag(): Promise<{ uid: Uint8Array; sak: number } | null>;
  /** Send a raw ISO 14443-A frame (with auto-select/CRC options) and return the response. */
  transceive14a(
    data: Uint8Array,
    opts?: { appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean },
  ): Promise<Uint8Array>;
  /** Read a 16-byte Mifare Classic block, authenticating with key A. */
  readBlock(block: number, key: Uint8Array): Promise<Uint8Array>;
  /** Write a 16-byte Mifare Classic block, authenticating with key A. */
  writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void>;
}

export const FACTORY_KEY_A = new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
```

- [ ] **Step 2: Update ChameleonBleTransport.awaitTag for the new scanTag shape**

In `webapp/src/transport/chameleon-ble.ts`, change the `awaitTag` loop body:

```ts
      if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const tag = await this.device.scanTag();
      if (tag !== null) return { uid: tag.uid, capacityBytes: CARD_CAPACITY_BYTES };
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
```

- [ ] **Step 3: Update the SDK adapter**

In `webapp/src/transport/sdk-chameleon-device.ts`: extend `ChameleonUltraSdk` and implement the new methods. Add to the `ChameleonUltraSdk` interface:

```ts
  cmdHf14aScan(): Promise<{ uid: Uint8Array; sak: Uint8Array }[]>;
  cmdHf14aRaw(opts: {
    data: Uint8Array; appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean;
    activateRfField?: boolean; keepRfField?: boolean; waitResponse?: boolean;
  }): Promise<Uint8Array>;
```

Replace the existing `scanTag` (keeping its `try/catch` that maps `TRANSIENT_SCAN_STATUSES` to `null`) with the version below, and add `transceive14a`:

```ts
  async scanTag(): Promise<{ uid: Uint8Array; sak: number } | null> {
    let tags: { uid: Uint8Array; sak: Uint8Array }[];
    try {
      tags = await this.sdk.cmdHf14aScan();
    } catch (err) {
      const status = statusOf(err);
      if (status !== undefined && TRANSIENT_SCAN_STATUSES.has(status)) return null;
      throw err;
    }
    const first = tags[0];
    return first ? { uid: new Uint8Array(first.uid), sak: first.sak[0] ?? 0 } : null;
  }

  async transceive14a(
    data: Uint8Array,
    opts?: { appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean },
  ): Promise<Uint8Array> {
    const resp = await this.sdk.cmdHf14aRaw({
      data: Buffer.from(data),
      appendCrc: opts?.appendCrc ?? false,
      autoSelect: opts?.autoSelect ?? false,
      checkResponseCrc: opts?.checkResponseCrc ?? false,
      waitResponse: true,
    });
    return new Uint8Array(resp);
  }
```

- [ ] **Step 4: Update FakeChameleon (scanTag shape + transceive14a stub)**

In `webapp/test/fake-chameleon.ts`: give each card an optional SAK (default `0x08`), return `{ uid, sak }` from `scanTag`, and add a `transceive14a` that throws for now. Change the `Card` interface and methods:

```ts
import { NotImplementedError } from '../src/transport/chameleon-ble.js';
```

If `NotImplementedError` is not exported there, define a local one in fake-chameleon.ts instead:

```ts
class NotImplementedError extends Error {
  constructor(m: string) { super(m); this.name = 'NotImplementedError'; }
}
```

Update the card record to carry a `sak` (default `0x08`), `place`/`defineCard` unchanged in signature, and:

```ts
  async scanTag(): Promise<{ uid: Uint8Array; sak: number } | null> {
    if (this.field === null) return null;
    const card = this.cards.get(this.field)!;
    return { uid: Uint8Array.from(this.field.match(/../g)!.map((h) => parseInt(h, 16))), sak: card.sak };
  }

  async transceive14a(): Promise<Uint8Array> {
    throw new NotImplementedError('transceive14a not simulated for this card');
  }
```

Extend the `Card` interface with `sak: number`, and change `defineCard` to accept an optional SAK so later tasks can place non-Classic tags:

```ts
  defineCard(uid: Uint8Array, opts?: { keyA?: Uint8Array; sak?: number }): void {
    this.cards.set(hex(uid), {
      image: new Uint8Array(64 * 16),
      keyA: opts?.keyA ?? FACTORY_KEY_A,
      sak: opts?.sak ?? 0x08,
    });
  }
```

- [ ] **Step 5: Update sdk-chameleon-device.test.ts's fake SDK for the new scan shape**

In `webapp/test/sdk-chameleon-device.test.ts`, the `fakeSdk`'s `cmdHf14aScan` must now return `sak`. Change its return and any scan assertions:

```ts
    async cmdHf14aScan() { calls.push(['scan']); return [{ uid: Buffer.from(new Uint8Array([1, 2, 3, 4])), sak: Buffer.from(new Uint8Array([0x08])) }]; },
```

And the `scanTag` assertion becomes:

```ts
test('scanTag returns the first tag UID + SAK, or null when none present', async () => {
  const dev = new SdkChameleonDevice(fakeSdk());
  assert.deepEqual(await dev.scanTag(), { uid: new Uint8Array([1, 2, 3, 4]), sak: 0x08 });
  const empty = new SdkChameleonDevice(fakeSdk({ async cmdHf14aScan() { return []; } }));
  assert.equal(await empty.scanTag(), null);
});
```

Keep the transient-status and null tests, updating any `cmdHf14aScan` overrides to include `sak` where they return a tag. Add a `cmdHf14aRaw` to the fake SDK returning an empty `Uint8Array` so the interface is satisfied.

- [ ] **Step 6: Run the suite and typecheck**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && echo CLEAN
```

Expected: PASS (96 total, unchanged count — this task edits existing tests, adds none) and `CLEAN`. The `chameleon-ble.test.ts` and contract tests still pass because `awaitTag` still returns `{ uid, capacityBytes }`.

- [ ] **Step 7: Commit**

```bash
git add webapp/src/transport/chameleon-device.ts webapp/src/transport/chameleon-ble.ts webapp/src/transport/sdk-chameleon-device.ts webapp/test/fake-chameleon.ts webapp/test/sdk-chameleon-device.test.ts
git commit -m "feat(webapp): extend ChameleonDevice seam — scanTag returns SAK, add transceive14a"
```

---

### Task 4: NtagTransport + FakeChameleon NTAG simulation

**Files:**
- Create: `webapp/src/transport/ntag-transport.ts`
- Modify: `webapp/test/fake-chameleon.ts` (add an NTAG simulation)
- Test: `webapp/test/ntag-transport.test.ts`

**Interfaces:**
- Consumes: `ChameleonDevice` (Task 3); `Transport`/`PresentedTag`/`TagTimeoutError`/`WriteVerifyError`/`CardCapacityError` (`./transport.js` + `../mifare/card-layout.js`); `encodeNdefMime`/`decodeNdefMime`/`NdefFormatError` (Task 1); `wrapType2Tlv`/`readType2Ndef`/`detectNtagType`/`ntagUserBytes`/`NtagType` (Task 2); `firstBlockIsNfar`/`nfarTotalLength` are NOT used (NTAG parses via NDEF).
- Produces:
  - `class NtagTransport implements Transport` — constructor `(device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number })`
  - `FakeChameleon` gains `placeNtag(uid: Uint8Array, type: NtagType): void` and simulates GET_VERSION / READ / WRITE over an in-memory page image.

- [ ] **Step 1: Add NTAG simulation to FakeChameleon**

In `webapp/test/fake-chameleon.ts`, add an NTAG card model. Each NTAG card holds a `pages: Uint8Array` (page count × 4 bytes), a `type: NtagType`, and `sak: 0x00`. `transceive14a` decodes the command:
- `0x60` (GET_VERSION) → return an 8-byte version with the storage byte set per type (`0x0f`/`0x11`/`0x13`).
- `0x30 <page>` (READ) → return 16 bytes starting at that page (4 pages).
- `0xA2 <page> b0 b1 b2 b3` (WRITE) → write those 4 bytes at that page, return a 1-byte ACK `0x0a`.

```ts
import { NtagType } from '../src/nfc/type2.js';

// page counts: 213=45, 215=135, 216=231
const NTAG_PAGES: Record<NtagType, number> = { NTAG213: 45, NTAG215: 135, NTAG216: 231 };
const NTAG_STORAGE: Record<NtagType, number> = { NTAG213: 0x0f, NTAG215: 0x11, NTAG216: 0x13 };

// In the FakeChameleon class, extend the card model with an optional ntag image:
//   interface Card { image: Uint8Array; keyA: Uint8Array; sak: number; ntag?: { type: NtagType; pages: Uint8Array } }

// Idempotent like place(): defines the NTAG only if new, so re-presenting the
// same UID keeps its written pages (needed for write→read-back tests).
placeNtag(uid: Uint8Array, type: NtagType): void {
  const key = hex(uid);
  if (!this.cards.has(key)) {
    this.cards.set(key, {
      image: new Uint8Array(64 * 16), keyA: FACTORY_KEY_A, sak: 0x00,
      ntag: { type, pages: new Uint8Array(NTAG_PAGES[type] * 4) },
    });
  }
  this.field = key;
}

async transceive14a(data: Uint8Array): Promise<Uint8Array> {
  const card = this.current();
  const ntag = card.ntag;
  if (!ntag) throw new CardAuthError('Not an NTAG card in field');
  const cmd = data[0];
  if (cmd === 0x60) { // GET_VERSION
    return new Uint8Array([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, NTAG_STORAGE[ntag.type], 0x03]);
  }
  if (cmd === 0x30) { // READ page..page+3 (16 bytes)
    const page = data[1]!;
    return ntag.pages.slice(page * 4, page * 4 + 16);
  }
  if (cmd === 0xa2) { // WRITE one page
    const page = data[1]!;
    ntag.pages.set(data.subarray(2, 6), page * 4);
    return new Uint8Array([0x0a]); // ACK
  }
  throw new CardAuthError(`Unsupported NTAG command 0x${cmd?.toString(16)}`);
}
```

(Replace the Task-3 `transceive14a` stub with this real one. `CardAuthError` is already imported in fake-chameleon.ts. `FACTORY_KEY_A` import too. Import `NtagType`.)

- [ ] **Step 2: Write the failing NtagTransport test**

`webapp/test/ntag-transport.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NtagTransport } from '../src/transport/ntag-transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType, ntagChunkPayloadSize } from '../src/nfc/type2.js';
import { encodeChunk, decodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

function chunkBytes(payloadLen: number): Uint8Array {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 3) % 256);
  const c: Chunk = { archiveId: new Uint8Array(16).fill(4), totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0 };
  return encodeChunk(c);
}

test('write then read-back an NDEF-wrapped chunk on a simulated NTAG215', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  const uid = new Uint8Array([0x04, 1, 2, 3, 4, 5, 6]);
  device.placeNtag(uid, NtagType.NTAG215);
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, 504);
  assert.equal(await t.peekIsNfar(), false);

  const bytes = chunkBytes(200);
  await t.writeChunk(bytes);
  device.placeNtag(uid, NtagType.NTAG215); // re-present the same card (keeps its pages)
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);
  assert.deepEqual(await t.readChunk(), bytes);
});

test('a chunk larger than the tag capacity is rejected', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.placeNtag(new Uint8Array([0x04, 9, 9, 9, 9, 9, 9]), NtagType.NTAG213);
  await t.awaitTag();
  const tooBig = chunkBytes(ntagChunkPayloadSize(NtagType.NTAG213) + 50);
  await assert.rejects(() => t.writeChunk(tooBig));
});
```

Note: `placeNtag` re-places the same card (same UID → same stored pages), so the written data persists for the read-back — do not create a fresh card. The stray `=== undefined` line above is a no-op kept only to document intent; replace it with a plain `device.placeNtag(uid, NtagType.NTAG215);` call.

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/ntag-transport.js'.

- [ ] **Step 4: Write NtagTransport**

`webapp/src/transport/ntag-transport.ts`:

```ts
/**
 * Transport over a Chameleon Ultra reading/writing NFAR chunks on NTAG213/215/216
 * as NDEF (Type-2). One NDEF-wrapped chunk per tag, matching the Android format.
 */

import { CardCapacityError } from '../mifare/card-layout.js';
import { encodeNdefMime, decodeNdefMime } from '../nfc/ndef.js';
import { wrapType2Tlv, readType2Ndef, detectNtagType, ntagUserBytes, ntagChunkPayloadSize, type NtagType } from '../nfc/type2.js';
import type { ChameleonDevice } from './chameleon-device.js';
import { NfarFormatError } from '../chunk.js';
import { TagTimeoutError, WriteVerifyError, type PresentedTag, type Transport } from './transport.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
const NDEF_START_PAGE = 4;

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export class NtagTransport implements Transport {
  readonly name = 'ntag';
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

  private async detectType(): Promise<NtagType> {
    const v = await this.device.transceive14a(new Uint8Array([0x60]), { autoSelect: true, appendCrc: true, checkResponseCrc: true });
    const t = detectNtagType(v);
    if (t === null) throw new NfarFormatError('Unsupported NTAG (GET_VERSION storage byte unrecognized)');
    return t;
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const timeoutMs = opts?.timeoutMs ?? this.defaultTimeoutMs;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const tag = await this.device.scanTag();
      if (tag !== null) {
        const type = await this.detectType();
        return { uid: tag.uid, capacityBytes: ntagUserBytes(type) };
      }
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  /** Read `pages` starting at `startPage`, 16 bytes per READ. */
  private async readMemory(startPage: number, byteCount: number): Promise<Uint8Array> {
    const out = new Uint8Array(Math.ceil(byteCount / 16) * 16);
    for (let off = 0; off < out.length; off += 16) {
      const resp = await this.device.transceive14a(new Uint8Array([0x30, startPage + off / 4]), { autoSelect: true, appendCrc: true, checkResponseCrc: true });
      out.set(resp.subarray(0, 16), off);
    }
    return out.subarray(0, byteCount);
  }

  async peekIsNfar(): Promise<boolean> {
    // Reuse readChunk: it fully parses TLV → NDEF → chunk and throws on any
    // blank/foreign tag. Correct for large chunks too (a 32-byte peek would
    // wrongly fail an NTAG216-sized record whose payload runs past 32 bytes).
    try {
      await this.readChunk();
      return true;
    } catch {
      return false;
    }
  }

  async readChunk(): Promise<Uint8Array> {
    // First 16 bytes give the TLV header + start of the NDEF; parse the TLV length to know the total.
    const head = await this.readMemory(NDEF_START_PAGE, 16);
    if (head[0] !== 0x03) throw new NfarFormatError('No NDEF TLV on this tag');
    let tlvLen = head[1]!;
    let ndefStart = 2;
    if (tlvLen === 0xff) { tlvLen = (head[2]! << 8) | head[3]!; ndefStart = 4; }
    const totalTlvBytes = ndefStart + tlvLen + 1; // + terminator
    const memory = await this.readMemory(NDEF_START_PAGE, totalTlvBytes);
    return decodeNdefMime(readType2Ndef(memory));
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const type = await this.detectType();
    if (bytes.length > 32 + ntagChunkPayloadSize(type)) {
      throw new CardCapacityError(`Chunk ${bytes.length} B exceeds ${type} capacity`);
    }
    const tlv = wrapType2Tlv(encodeNdefMime(bytes));
    const padded = new Uint8Array(Math.ceil(tlv.length / 4) * 4);
    padded.set(tlv);
    const pageCount = padded.length / 4;
    for (let p = 0; p < pageCount; p++) {
      await this.device.transceive14a(
        new Uint8Array([0xa2, NDEF_START_PAGE + p, ...padded.subarray(p * 4, p * 4 + 4)]),
        { autoSelect: true, appendCrc: true },
      );
    }
    // Read-back verify.
    const readBack = await this.readMemory(NDEF_START_PAGE, padded.length);
    if (!bytesEqual(readBack, padded)) throw new WriteVerifyError('NTAG read-back does not match written pages');
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (96 + 2 = 98 total). If the read-back verify fails, the fake's READ returns 16 bytes past the written region as zeros, and `padded` is page-aligned, so the compared lengths match — verify the fake pages array is large enough (it is: full NTAG page count).

- [ ] **Step 6: Commit**

```bash
git add webapp/src/transport/ntag-transport.ts webapp/test/fake-chameleon.ts webapp/test/ntag-transport.test.ts
git commit -m "feat(webapp): NtagTransport (Type-2/NDEF) + FakeChameleon NTAG simulation"
```

---

### Task 5: AutoTransport — route by SAK

**Files:**
- Create: `webapp/src/transport/auto-transport.ts`
- Modify: `webapp/src/transport/transport.ts` (add `UnsupportedTagError`)
- Test: `webapp/test/auto-transport.test.ts`

**Interfaces:**
- Consumes: `ChameleonDevice` (Task 3); `ChameleonBleTransport` (`./chameleon-ble.js`); `NtagTransport` (Task 4); `Transport`/`PresentedTag`/`TagTimeoutError` (`./transport.js`).
- Produces:
  - `class UnsupportedTagError extends Error` (in transport.ts)
  - `class AutoTransport implements Transport` — constructor `(device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number })`

- [ ] **Step 1: Add UnsupportedTagError**

In `webapp/src/transport/transport.ts`, add:

```ts
export class UnsupportedTagError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnsupportedTagError';
  }
}
```

- [ ] **Step 2: Write the failing test**

`webapp/test/auto-transport.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType } from '../src/nfc/type2.js';
import { CARD_CAPACITY_BYTES } from '../src/mifare/card-layout.js';

test('a Mifare Classic (SAK 0x08) routes to the Classic transport', async () => {
  const device = new FakeChameleon();
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.place(new Uint8Array([1, 2, 3, 4])); // FakeChameleon default sak 0x08
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, CARD_CAPACITY_BYTES); // 752 => Classic delegate
});

test('an NTAG (SAK 0x00) routes to the NTAG transport', async () => {
  const device = new FakeChameleon();
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.placeNtag(new Uint8Array([0x04, 1, 2, 3, 4, 5, 6]), NtagType.NTAG216);
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, 888); // NTAG216 => NTAG delegate
});

test('an unknown SAK throws UnsupportedTagError', async () => {
  const device = new FakeChameleon();
  device.defineCard(new Uint8Array([7, 7, 7, 7]), { sak: 0x20 });
  device.place(new Uint8Array([7, 7, 7, 7]));
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await t.connect();
  await assert.rejects(() => t.awaitTag(), UnsupportedTagError);
});
```

Note: `defineCard` already accepts an optional `sak` (added in Task 3), so `defineCard(uid, { sak: 0x20 })` works without touching `fake-chameleon.ts` here.

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/auto-transport.js'.

- [ ] **Step 4: Write AutoTransport**

`webapp/src/transport/auto-transport.ts`:

```ts
/**
 * Routes each presented tag to the right transport by its SAK: Mifare Classic 1K
 * (0x08) → ChameleonBleTransport, NTAG/Type-2 (0x00) → NtagTransport. The UI uses
 * this, so archive/restore work across both media transparently.
 */

import type { ChameleonDevice } from './chameleon-device.js';
import { ChameleonBleTransport } from './chameleon-ble.js';
import { NtagTransport } from './ntag-transport.js';
import { TagTimeoutError, UnsupportedTagError, type PresentedTag, type Transport } from './transport.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class AutoTransport implements Transport {
  readonly name = 'auto';
  private readonly classic: ChameleonBleTransport;
  private readonly ntag: NtagTransport;
  private active: Transport | null = null;
  private readonly pollMs: number;
  private readonly defaultTimeoutMs: number;

  constructor(private readonly device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number }) {
    this.classic = new ChameleonBleTransport(device, opts);
    this.ntag = new NtagTransport(device, opts);
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
      const tag = await this.device.scanTag();
      if (tag !== null) {
        if (tag.sak === 0x08) this.active = this.classic;
        else if (tag.sak === 0x00) this.active = this.ntag;
        else throw new UnsupportedTagError(`Unsupported tag (SAK 0x${tag.sak.toString(16)})`);
        // The chosen delegate re-reads the present tag for capacity/type.
        return this.active.awaitTag({ ...opts, timeoutMs });
      }
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  private delegate(): Transport {
    if (this.active === null) throw new TagTimeoutError('No tag has been awaited yet');
    return this.active;
  }

  peekIsNfar(): Promise<boolean> { return this.delegate().peekIsNfar(); }
  readChunk(): Promise<Uint8Array> { return this.delegate().readChunk(); }
  writeChunk(bytes: Uint8Array): Promise<void> { return this.delegate().writeChunk(bytes); }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (98 + 3 = 101 total). The delegate's `awaitTag` re-scans (finds the same present tag) and returns the correct capacity; the double scan is harmless.

- [ ] **Step 6: Commit**

```bash
git add webapp/src/transport/auto-transport.ts webapp/src/transport/transport.ts webapp/test/auto-transport.test.ts
git commit -m "feat(webapp): AutoTransport routes tags by SAK to Classic or NTAG"
```

---

### Task 6: payloadSize parameter + end-to-end over NTAG

**Files:**
- Modify: `webapp/app/controller.ts` (ArchiveRequest + prepare), `webapp/app/estimate.ts` (estimateCardCount), `webapp/test/controller.test.ts`, `webapp/test/estimate.test.ts`
- Test: `webapp/test/e2e-ntag.test.ts`

**Interfaces:**
- Consumes: `AutoTransport` (Task 5), `FakeChameleon` (`placeNtag`), `NtagType`/`ntagChunkPayloadSize` (Task 2), `archive`/`restore`, `encodeChunk`/`decodeChunk`.
- Produces:
  - `ArchiveRequest` gains `payloadSize: number`; `ArchiveController.prepare` uses it (instead of `CARD_PAYLOAD_SIZE`).
  - `estimateCardCount(data, fileName, { compress, encrypted, payloadSize })` — `payloadSize` added.

- [ ] **Step 1: Add payloadSize to ArchiveController**

In `webapp/app/controller.ts`: add `payloadSize: number` to `ArchiveRequest`, and in `prepare` change `payloadSize: CARD_PAYLOAD_SIZE` to `payloadSize: req.payloadSize`. Remove the now-unused `CARD_PAYLOAD_SIZE` import if nothing else uses it (check: `RestoreController` does not).

- [ ] **Step 2: Add payloadSize to estimateCardCount**

In `webapp/app/estimate.ts`, change the signature and body:

```ts
export async function estimateCardCount(
  data: Uint8Array,
  fileName: string,
  opts: { compress: boolean; encrypted: boolean; payloadSize: number },
): Promise<number> {
  if (data.length === 0) return 0;
  const wrapped = wrapWithFilename(data, fileName);
  let processed = wrapped;
  if (opts.compress) {
    const gz = await gzipCompress(wrapped);
    if (gz.length < wrapped.length) processed = gz;
  }
  const size = processed.length + (opts.encrypted ? ENCRYPTION_OVERHEAD : 0);
  return Math.ceil(size / opts.payloadSize);
}
```

Remove the `CARD_PAYLOAD_SIZE` import from estimate.ts.

- [ ] **Step 3: Update the existing controller and estimate tests**

In `webapp/test/controller.test.ts`, every `prepare({ ... })` call gains `payloadSize: 720` (add it to the helper `archiveToCards`'s prepare call and the direct prepare calls). In `webapp/test/estimate.test.ts`, every `estimateCardCount(...)` call gains `payloadSize: 720` in its options (the existing expected counts were computed against 720, so they stay valid).

- [ ] **Step 4: Write the end-to-end NTAG test**

`webapp/test/e2e-ntag.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archive, restore } from '../src/pipeline.js';
import { encodeChunk, decodeChunk, type Chunk } from '../src/chunk.js';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType, ntagChunkPayloadSize } from '../src/nfc/type2.js';

test('archive to NTAG215 tags via AutoTransport, then restore byte-identical', async () => {
  const original = new TextEncoder().encode('ntag payload '.repeat(120));
  const device = new FakeChameleon();
  const transport = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await transport.connect();

  const payloadSize = ntagChunkPayloadSize(NtagType.NTAG215);
  const chunks = await archive(original, { payloadSize, compress: false, password: 'ntag-pw' });
  assert.ok(chunks.length >= 2, `expected multiple NTAGs, got ${chunks.length}`);

  const uids = chunks.map((_, i) => new Uint8Array([0x04, 0, 0, 0, 0, 0, i]));
  for (let i = 0; i < chunks.length; i++) {
    device.placeNtag(uids[i]!, NtagType.NTAG215);
    await transport.awaitTag();
    await transport.writeChunk(encodeChunk(chunks[i]!));
  }

  const collected: Chunk[] = [];
  for (const uid of [...uids].reverse()) {
    device.placeNtag(uid, NtagType.NTAG215);
    await transport.awaitTag();
    collected.push(decodeChunk(await transport.readChunk()));
  }
  assert.deepEqual(await restore(collected, 'ntag-pw'), original);
});
```

- [ ] **Step 5: Run the suite**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && echo CLEAN
```

Expected: PASS (101 + 1 = 102 total), `CLEAN`. If the e2e chunk count is 1, grow the payload (`'ntag payload '.repeat(120)` is ~1.5 KB, which at ~430 B/NTAG215 chunk gives ≥ 3 chunks).

- [ ] **Step 6: Commit**

```bash
git add webapp/app/controller.ts webapp/app/estimate.ts webapp/test/controller.test.ts webapp/test/estimate.test.ts webapp/test/e2e-ntag.test.ts
git commit -m "feat(webapp): payloadSize parameter for chunking; end-to-end archive/restore over NTAG"
```

---

### Task 7: UI — target-tag selector, AutoTransport wiring, About copy

**Files:**
- Modify: `webapp/app/index.html`, `webapp/app/ui/device.ts`, `webapp/app/ui/archive-panel.ts`, `webapp/app/ui/errors.ts`, `webapp/app/ui/about-panel.ts`

**Interfaces:**
- Consumes: `AutoTransport` (Task 5); `estimateCardCount` with `payloadSize` (Task 6); `NtagType`/`ntagChunkPayloadSize` (Task 2); `CARD_PAYLOAD_SIZE` (`../../src/mifare/card-layout.js`); `UnsupportedTagError`/`NdefFormatError` for `humanError`.
- Produces: no exported API. DOM glue; verified by tsc + bundle.

- [ ] **Step 1: device.ts constructs AutoTransport**

In `webapp/app/ui/device.ts`, change the transport construction and type. Replace the `ChameleonBleTransport` import with `AutoTransport`:

```ts
import { AutoTransport } from '../../src/transport/auto-transport.js';
// ...
let transport: AutoTransport | null = null;
// ...in connect():
transport = new AutoTransport(new SdkChameleonDevice(ultra));
```

Update `currentTransport(): AutoTransport | null` accordingly. (Remove the `ChameleonBleTransport` import.)

- [ ] **Step 2: Add the target-tag selector to the Archive panel markup**

In `webapp/app/index.html`, inside `#panel-archive`'s first `.card`, add before the compress/password row:

```html
          <div style="margin-top:0.6rem"><label>target tag
            <select id="target-tag">
              <option value="720">Mifare Classic 1K</option>
              <option value="NTAG213">NTAG213</option>
              <option value="NTAG215">NTAG215</option>
              <option value="NTAG216">NTAG216</option>
            </select></label></div>
```

- [ ] **Step 3: Wire the selector into archive-panel.ts**

In `webapp/app/ui/archive-panel.ts`, add a helper to resolve the selected payload size and pass it to `prepare` and the counter:

```ts
import { NtagType, ntagChunkPayloadSize } from '../../src/nfc/type2.js';

function selectedPayloadSize(): number {
  const v = ($('target-tag') as HTMLSelectElement).value;
  if (v === 'NTAG213') return ntagChunkPayloadSize(NtagType.NTAG213);
  if (v === 'NTAG215') return ntagChunkPayloadSize(NtagType.NTAG215);
  if (v === 'NTAG216') return ntagChunkPayloadSize(NtagType.NTAG216);
  return Number(v); // "720" for Mifare Classic 1K
}
```

In `updateCounter`, pass `payloadSize: selectedPayloadSize()` to `estimateCardCount`; recompute the counter when the selector changes (`$('target-tag').addEventListener('change', scheduleCounter)`). In the `#archive` click handler, pass `payloadSize: selectedPayloadSize()` to `ctrl.prepare({ ... })`.

- [ ] **Step 4: Map the new errors in humanError**

In `webapp/app/ui/errors.ts`, import and map the new types:

```ts
import { CardAuthError, WriteVerifyError, TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { NdefFormatError } from '../../src/nfc/ndef.js';
// ...in humanError, before the generic fallback:
  if (e instanceof UnsupportedTagError) return 'Unsupported tag — use a Mifare Classic 1K or NTAG213/215/216.';
  if (e instanceof NdefFormatError) return 'This tag holds no NFAR NDEF data.';
```

Add matching assertions to `webapp/test/errors.test.ts` for the two new mappings.

- [ ] **Step 5: Update the About supported-tags copy**

In `webapp/app/ui/about-panel.ts`, change the "Supported tags" body to:

```ts
  { h: 'Supported tags', body: [
    'Mifare Classic 1K and NTAG213/215/216, via a Chameleon Ultra over Web Bluetooth.',
    '(Writing NTAG with the phone’s own NFC — no Chameleon — will come with the future Web NFC support.)',
  ] },
```

- [ ] **Step 6: Verify**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-ntag-check.js >/dev/null && echo BUNDLE OK
```

Expected: PASS (102 + 2 new errors tests = 104), `tsc` clean, `BUNDLE OK`. Confirm the dependency fence still holds: `grep -rl "chameleon-ultra" webapp/app webapp/src --include="*.ts"` lists only `app/ui/device.ts`, `src/transport/sdk-chameleon-device.ts` (+ the doc comment in `chameleon-device.ts`).

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/device.ts webapp/app/ui/archive-panel.ts webapp/app/ui/errors.ts webapp/app/ui/about-panel.ts webapp/test/errors.test.ts
git commit -m "feat(webapp): target-tag selector, AutoTransport wiring, NTAG About copy"
```

---

## Completion Criteria

- `npm test` in `webapp/` passes (104 tests) on Node LTS.
- `npx tsc --noEmit` clean; `npx esbuild app/main.ts --bundle` succeeds.
- Dependency fence holds: `chameleon-ultra.js` only in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`.
- NFAR core unchanged; controllers changed only by the additive `payloadSize` parameter.
- No new runtime dependencies.
- Manual (`npm run app`, real hardware): a Mifare Classic 1K and an NTAG both archive/restore end-to-end; a tag written on the Chameleon-web app is readable by an NFC phone (NDEF) — new `HARDWARE_TESTING.md` items.
