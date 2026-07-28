# Web App NFAR Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A TypeScript port of the NFAR v1 core (CRC-32, chunk codec, chunker, AES-256-GCM/PBKDF2, GZIP, archive/restore pipeline, transport abstraction) proven byte-compatible with the Dart implementation via cross-language fixtures.

**Architecture:** Zero-runtime-dependency TS modules in `webapp/src/` using only web-platform globals (`crypto.subtle`, `CompressionStream`, `DataView`), tested with `node:test` against `tsc` output. Two Dart CLI scripts in `tool/` use the app's production `lib/core` services to generate and verify interop fixtures.

**Tech Stack:** TypeScript 5 (dev-only dep), Node ≥ 18 (via nvm, LTS), `node:test`, Dart (repo's existing toolchain).

**Spec:** `docs/superpowers/specs/2026-07-27-webapp-nfar-core-design.md` — its Compatibility Contract table is normative.

## Global Constraints

- Zero **runtime** dependencies in `webapp/`; dev deps are exactly `typescript` and `@types/node`.
- All multi-byte header fields are **big-endian**.
- Header layout: `NFAR`(4) ‖ version `0x01`(1) ‖ flags(1) ‖ archiveId(16) ‖ totalChunks u16 ‖ chunkIndex u16 ‖ payloadSize u16 ‖ payload ‖ CRC-32 u32. Payload starts at offset 28; total overhead 32 bytes.
- Flags: bit 0 = GZIP (`0x01`), bit 1 = AES-256-GCM (`0x02`).
- CRC-32: reflected, polynomial `0xEDB88320`, init/xorout `0xFFFFFFFF`, computed over payload only.
- Encryption blob: `salt(16) ‖ iv(12) ‖ ciphertext ‖ tag(16)`; PBKDF2-HMAC-SHA256, 100 000 iterations, 32-byte key; password is `.trim()`ed then UTF-8 encoded.
- Limits: max 65 535 chunks, max 65 535-byte payload.
- Every test command runs with Node LTS: prefix `source ~/.nvm/nvm.sh && nvm use --lts` (do **not** change the nvm default alias).
- All commits go on branch `webapp-nfar-core-prototype`.

---

### Task 1: Scaffold `webapp/` and CRC-32

**Files:**
- Create: `webapp/package.json`, `webapp/tsconfig.json`, `webapp/.gitignore`
- Create: `webapp/src/crc32.ts`
- Test: `webapp/test/crc32.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `crc32(data: Uint8Array): number` — unsigned 32-bit result.

- [ ] **Step 1: Install Node LTS (one-time)**

```bash
source ~/.nvm/nvm.sh && nvm install --lts
```

Expected: installs Node 24.x; do not run `nvm alias default`.

- [ ] **Step 2: Create project files**

`webapp/package.json`:

```json
{
  "name": "nfcarchiver-web-core",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc",
    "test": "tsc && node --test dist/test/",
    "fixtures": "tsc && node dist/test/write_ts_fixtures.js"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "typescript": "^5.5.0"
  }
}
```

`webapp/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022", "DOM"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "outDir": "dist",
    "rootDir": ".",
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts", "test/**/*.ts"]
}
```

`webapp/.gitignore`:

```
node_modules/
dist/
```

Then:

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm install
```

Expected: installs 2 dev packages, creates `package-lock.json`.

- [ ] **Step 3: Write the failing test**

`webapp/test/crc32.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crc32 } from '../src/crc32.js';

test('crc32 check vector "123456789" -> 0xCBF43926', () => {
  assert.equal(crc32(new TextEncoder().encode('123456789')), 0xcbf43926);
});

test('crc32 of empty input is 0', () => {
  assert.equal(crc32(new Uint8Array(0)), 0);
});

test('crc32 result is unsigned', () => {
  // "a" -> 0xE8B7BE43, which is negative as a signed 32-bit int
  assert.equal(crc32(new TextEncoder().encode('a')), 0xe8b7be43);
});
```

- [ ] **Step 4: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — `tsc` error TS2307: Cannot find module '../src/crc32.js'.

- [ ] **Step 5: Write minimal implementation**

`webapp/src/crc32.ts`:

```ts
/** Reflected CRC-32 (IEEE 802.3 / zlib variant), matching the Dart ChecksumService. */

const TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 1) !== 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
    table[i] = crc >>> 0;
  }
  return table;
})();

export function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = TABLE[(crc ^ data[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
```

- [ ] **Step 6: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS, 3 tests.

- [ ] **Step 7: Commit**

```bash
git add webapp/package.json webapp/package-lock.json webapp/tsconfig.json webapp/.gitignore webapp/src/crc32.ts webapp/test/crc32.test.ts
git commit -m "feat(webapp): scaffold TS core, add zlib-variant CRC-32"
```

---

### Task 2: Chunk codec

**Files:**
- Create: `webapp/src/chunk.ts`
- Create: `webapp/test/hex.ts` (shared test helper)
- Test: `webapp/test/chunk.test.ts`

**Interfaces:**
- Consumes: `crc32` from Task 1 (in tests only).
- Produces:
  - `interface Chunk { archiveId: Uint8Array; totalChunks: number; chunkIndex: number; payload: Uint8Array; crc32: number; flags: number }`
  - `encodeChunk(chunk: Chunk): Uint8Array`, `decodeChunk(data: Uint8Array): Chunk`
  - `class NfarFormatError extends Error`
  - Constants: `NFAR_MAGIC`, `NFAR_VERSION`, `HEADER_SIZE = 28`, `TOTAL_OVERHEAD = 32`, `FLAG_COMPRESSED = 0x01`, `FLAG_ENCRYPTED = 0x02`, `MAX_CHUNKS = 65535`, `MAX_PAYLOAD_SIZE = 65535`
  - Test helper: `toHex(b: Uint8Array): string`, `fromHex(s: string): Uint8Array`

- [ ] **Step 1: Write the shared hex helper**

`webapp/test/hex.ts`:

```ts
export function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}
```

- [ ] **Step 2: Write the failing test**

`webapp/test/chunk.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crc32 } from '../src/crc32.js';
import {
  encodeChunk, decodeChunk, NfarFormatError, TOTAL_OVERHEAD,
  FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk,
} from '../src/chunk.js';
import { toHex } from './hex.js';

function sampleChunk(): Chunk {
  const payload = new Uint8Array([1, 2, 3, 4, 5]);
  return {
    archiveId: new Uint8Array(16).map((_, i) => i),
    totalChunks: 3,
    chunkIndex: 1,
    payload,
    crc32: crc32(payload),
    flags: FLAG_COMPRESSED | FLAG_ENCRYPTED,
  };
}

test('encodeChunk produces the exact NFAR v1 layout', () => {
  const bytes = encodeChunk(sampleChunk());
  assert.equal(bytes.length, TOTAL_OVERHEAD + 5);
  assert.equal(toHex(bytes.subarray(0, 4)), '4e464152'); // "NFAR"
  assert.equal(bytes[4], 0x01); // version
  assert.equal(bytes[5], 0x03); // flags
  assert.equal(toHex(bytes.subarray(6, 22)), '000102030405060708090a0b0c0d0e0f');
  assert.equal(toHex(bytes.subarray(22, 24)), '0003'); // totalChunks BE
  assert.equal(toHex(bytes.subarray(24, 26)), '0001'); // chunkIndex BE
  assert.equal(toHex(bytes.subarray(26, 28)), '0005'); // payloadSize BE
  assert.equal(toHex(bytes.subarray(28, 33)), '0102030405');
});

test('decodeChunk round-trips encodeChunk byte-for-byte', () => {
  const original = sampleChunk();
  const decoded = decodeChunk(encodeChunk(original));
  assert.deepEqual(decoded, original);
  assert.deepEqual(encodeChunk(decoded), encodeChunk(original));
});

test('decodeChunk rejects short data, bad magic, bad version', () => {
  assert.throws(() => decodeChunk(new Uint8Array(10)), NfarFormatError);
  const badMagic = encodeChunk(sampleChunk());
  badMagic[0] = 0x58;
  assert.throws(() => decodeChunk(badMagic), NfarFormatError);
  const badVersion = encodeChunk(sampleChunk());
  badVersion[4] = 0x02;
  assert.throws(() => decodeChunk(badVersion), NfarFormatError);
});

test('decodeChunk rejects truncated payload', () => {
  const bytes = encodeChunk(sampleChunk());
  assert.throws(() => decodeChunk(bytes.subarray(0, bytes.length - 3)), NfarFormatError);
});

test('decodeChunk works on a view with non-zero byteOffset', () => {
  const bytes = encodeChunk(sampleChunk());
  const padded = new Uint8Array(bytes.length + 7);
  padded.set(bytes, 7);
  assert.deepEqual(decodeChunk(padded.subarray(7)), sampleChunk());
});

test('encodeChunk validates archiveId length', () => {
  const bad = { ...sampleChunk(), archiveId: new Uint8Array(15) };
  assert.throws(() => encodeChunk(bad), NfarFormatError);
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/chunk.js'.

- [ ] **Step 4: Write minimal implementation**

`webapp/src/chunk.ts`:

```ts
/** NFAR v1 chunk codec. Mirrors lib/core/constants/nfar_format.dart and lib/core/models/chunk.dart. */

export const NFAR_MAGIC = new Uint8Array([0x4e, 0x46, 0x41, 0x52]); // "NFAR"
export const NFAR_VERSION = 0x01;
export const HEADER_SIZE = 28; // fields before payload
export const CRC_SIZE = 4;
export const TOTAL_OVERHEAD = HEADER_SIZE + CRC_SIZE; // 32
export const FLAG_COMPRESSED = 0x01;
export const FLAG_ENCRYPTED = 0x02;
export const MAX_CHUNKS = 65535;
export const MAX_PAYLOAD_SIZE = 65535;

export class NfarFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NfarFormatError';
  }
}

export interface Chunk {
  archiveId: Uint8Array; // 16 bytes
  totalChunks: number;
  chunkIndex: number;
  payload: Uint8Array;
  crc32: number;
  flags: number;
}

export function encodeChunk(chunk: Chunk): Uint8Array {
  if (chunk.archiveId.length !== 16) {
    throw new NfarFormatError(`Archive ID must be 16 bytes, got ${chunk.archiveId.length}`);
  }
  if (chunk.payload.length > MAX_PAYLOAD_SIZE) {
    throw new NfarFormatError(`Payload too large: ${chunk.payload.length}`);
  }
  const out = new Uint8Array(TOTAL_OVERHEAD + chunk.payload.length);
  const view = new DataView(out.buffer);
  out.set(NFAR_MAGIC, 0);
  out[4] = NFAR_VERSION;
  out[5] = chunk.flags;
  out.set(chunk.archiveId, 6);
  view.setUint16(22, chunk.totalChunks);
  view.setUint16(24, chunk.chunkIndex);
  view.setUint16(26, chunk.payload.length);
  out.set(chunk.payload, HEADER_SIZE);
  view.setUint32(HEADER_SIZE + chunk.payload.length, chunk.crc32);
  return out;
}

export function decodeChunk(data: Uint8Array): Chunk {
  if (data.length < TOTAL_OVERHEAD) {
    throw new NfarFormatError(
      `Data too short: expected at least ${TOTAL_OVERHEAD} bytes, got ${data.length}`,
    );
  }
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (data[i] !== NFAR_MAGIC[i]) {
      throw new NfarFormatError('Invalid magic bytes: not an NFAR chunk');
    }
  }
  const version = data[4]!;
  if (version !== NFAR_VERSION) {
    throw new NfarFormatError(`Unsupported version: ${version} (expected ${NFAR_VERSION})`);
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const flags = data[5]!;
  const archiveId = data.slice(6, 22);
  const totalChunks = view.getUint16(22);
  const chunkIndex = view.getUint16(24);
  const payloadSize = view.getUint16(26);
  const expectedTotal = HEADER_SIZE + payloadSize + CRC_SIZE;
  if (data.length < expectedTotal) {
    throw new NfarFormatError(
      `Data too short for payload: expected ${expectedTotal} bytes, got ${data.length}`,
    );
  }
  const payload = data.slice(HEADER_SIZE, HEADER_SIZE + payloadSize);
  const crc = view.getUint32(HEADER_SIZE + payloadSize);
  return { archiveId, totalChunks, chunkIndex, payload, crc32: crc, flags };
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (9 tests total).

- [ ] **Step 6: Commit**

```bash
git add webapp/src/chunk.ts webapp/test/chunk.test.ts webapp/test/hex.ts
git commit -m "feat(webapp): NFAR v1 chunk encode/decode"
```

---

### Task 3: Chunker and assembler

**Files:**
- Create: `webapp/src/chunker.ts`
- Test: `webapp/test/chunker.test.ts`

**Interfaces:**
- Consumes: `Chunk`, `MAX_CHUNKS`, `MAX_PAYLOAD_SIZE` (Task 2); `crc32` (Task 1).
- Produces:
  - `createChunks(data: Uint8Array, payloadSize: number, flags?: number, archiveId?: Uint8Array): Chunk[]`
  - `assembleChunks(chunks: Chunk[]): Uint8Array`
  - `generateArchiveId(): Uint8Array` (UUID v4 bytes)
  - `class NfarAssemblyError extends Error`

- [ ] **Step 1: Write the failing test**

`webapp/test/chunker.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createChunks, assembleChunks, generateArchiveId, NfarAssemblyError } from '../src/chunker.js';

const data = new Uint8Array(200).map((_, i) => i % 251);

test('createChunks splits with correct sizes, indices, CRCs', () => {
  const chunks = createChunks(data, 64);
  assert.equal(chunks.length, 4); // 64+64+64+8
  assert.deepEqual(chunks.map((c) => c.payload.length), [64, 64, 64, 8]);
  assert.deepEqual(chunks.map((c) => c.chunkIndex), [0, 1, 2, 3]);
  assert.ok(chunks.every((c) => c.totalChunks === 4));
  assert.ok(chunks.every((c) => c.archiveId === chunks[0]!.archiveId));
});

test('assembleChunks restores original from shuffled chunks', () => {
  const chunks = createChunks(data, 64);
  const shuffled = [chunks[2]!, chunks[0]!, chunks[3]!, chunks[1]!];
  assert.deepEqual(assembleChunks(shuffled), data);
});

test('assembleChunks rejects empty, missing, duplicate, corrupted', () => {
  assert.throws(() => assembleChunks([]), NfarAssemblyError);

  const missing = createChunks(data, 64).filter((c) => c.chunkIndex !== 2);
  assert.throws(() => assembleChunks(missing), /Missing chunks: 2/);

  const chunks = createChunks(data, 64);
  assert.throws(() => assembleChunks([...chunks, chunks[1]!]), /Duplicate/);

  // Corrupt via the crc field, not the payload: payloads are subarray views
  // into the shared test data, so mutating them would poison later tests.
  const corrupted = createChunks(data, 64);
  corrupted[1] = { ...corrupted[1]!, crc32: corrupted[1]!.crc32 ^ 0xff };
  assert.throws(() => assembleChunks(corrupted), /CRC mismatch for chunk 1/);
});

test('assembleChunks rejects mixed archives', () => {
  const a = createChunks(data, 64);
  const b = createChunks(data, 64);
  assert.throws(() => assembleChunks([a[0]!, b[1]!, a[2]!, a[3]!]), /different archives/);
});

test('createChunks validates payloadSize and data size limits', () => {
  assert.throws(() => createChunks(data, 0), RangeError);
  assert.throws(() => createChunks(data, 65536), RangeError);
  assert.throws(() => createChunks(new Uint8Array(65536 * 2), 1), RangeError); // > 65535 chunks
});

test('generateArchiveId returns 16 bytes with UUID v4 markers', () => {
  const id = generateArchiveId();
  assert.equal(id.length, 16);
  assert.equal(id[6]! & 0xf0, 0x40); // version nibble
  assert.equal(id[8]! & 0xc0, 0x80); // variant bits
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/chunker.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/chunker.ts`:

```ts
/** Splitting and reassembly, mirroring lib/core/services/chunker_service.dart. */

import { crc32 } from './crc32.js';
import { MAX_CHUNKS, MAX_PAYLOAD_SIZE, type Chunk } from './chunk.js';

export class NfarAssemblyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NfarAssemblyError';
  }
}

export function generateArchiveId(): Uint8Array {
  const id = crypto.getRandomValues(new Uint8Array(16));
  id[6] = (id[6]! & 0x0f) | 0x40; // UUID version 4
  id[8] = (id[8]! & 0x3f) | 0x80; // RFC 4122 variant
  return id;
}

export function createChunks(
  data: Uint8Array,
  payloadSize: number,
  flags = 0,
  archiveId?: Uint8Array,
): Chunk[] {
  if (payloadSize <= 0) throw new RangeError('Payload size must be positive');
  if (payloadSize > MAX_PAYLOAD_SIZE) {
    throw new RangeError(`Payload size too large: ${payloadSize} > ${MAX_PAYLOAD_SIZE}`);
  }
  const id = archiveId ?? generateArchiveId();
  const totalChunks = Math.ceil(data.length / payloadSize);
  if (totalChunks > MAX_CHUNKS) {
    throw new RangeError(`Data too large: would need ${totalChunks} chunks, maximum is ${MAX_CHUNKS}`);
  }
  const chunks: Chunk[] = [];
  for (let i = 0; i < totalChunks; i++) {
    const payload = data.subarray(i * payloadSize, Math.min((i + 1) * payloadSize, data.length));
    chunks.push({ archiveId: id, totalChunks, chunkIndex: i, payload, crc32: crc32(payload), flags });
  }
  return chunks;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export function assembleChunks(chunks: Chunk[]): Uint8Array {
  if (chunks.length === 0) throw new NfarAssemblyError('No chunks provided');
  const sorted = [...chunks].sort((a, b) => a.chunkIndex - b.chunkIndex);
  const { archiveId, totalChunks } = sorted[0]!;
  for (const c of sorted) {
    if (!bytesEqual(c.archiveId, archiveId)) {
      throw new NfarAssemblyError('Chunks are from different archives');
    }
    if (c.totalChunks !== totalChunks) {
      throw new NfarAssemblyError(`Inconsistent total chunks: ${totalChunks} vs ${c.totalChunks}`);
    }
  }
  const indices = new Set(sorted.map((c) => c.chunkIndex));
  const missing: number[] = [];
  for (let i = 0; i < totalChunks; i++) if (!indices.has(i)) missing.push(i);
  if (missing.length > 0) throw new NfarAssemblyError(`Missing chunks: ${missing.join(', ')}`);
  if (sorted.length !== totalChunks) {
    throw new NfarAssemblyError(`Duplicate chunks detected: have ${sorted.length}, expected ${totalChunks}`);
  }
  for (const c of sorted) {
    if (crc32(c.payload) !== c.crc32) {
      throw new NfarAssemblyError(`CRC mismatch for chunk ${c.chunkIndex}: data may be corrupted`);
    }
  }
  let totalSize = 0;
  for (const c of sorted) totalSize += c.payload.length;
  const out = new Uint8Array(totalSize);
  let offset = 0;
  for (const c of sorted) {
    out.set(c.payload, offset);
    offset += c.payload.length;
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (15 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/chunker.ts webapp/test/chunker.test.ts
git commit -m "feat(webapp): chunker and assembler with Dart-equivalent validation"
```

---

### Task 4: AES-256-GCM + PBKDF2 crypto

**Files:**
- Create: `webapp/src/crypto.ts`
- Test: `webapp/test/crypto.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `encrypt(data: Uint8Array, password: string): Promise<Uint8Array>`
  - `decrypt(blob: Uint8Array, password: string): Promise<Uint8Array>`
  - `class DecryptionError extends Error`
  - `ENCRYPTION_OVERHEAD = 44`

- [ ] **Step 1: Write the failing test**

`webapp/test/crypto.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encrypt, decrypt, DecryptionError, ENCRYPTION_OVERHEAD } from '../src/crypto.js';

const data = new Uint8Array(100).map((_, i) => (i * 7) % 256);

test('encrypt/decrypt round-trip', async () => {
  const blob = await encrypt(data, 'secret-password');
  assert.equal(blob.length, data.length + ENCRYPTION_OVERHEAD);
  assert.deepEqual(await decrypt(blob, 'secret-password'), data);
});

test('password is trimmed like the Dart implementation', async () => {
  const blob = await encrypt(data, '  padded  ');
  assert.deepEqual(await decrypt(blob, 'padded'), data);
  assert.deepEqual(await decrypt(blob, '\tpadded\n'), data);
});

test('wrong password throws DecryptionError', async () => {
  const blob = await encrypt(data, 'right');
  await assert.rejects(() => decrypt(blob, 'wrong'), DecryptionError);
});

test('tampered ciphertext throws DecryptionError', async () => {
  const blob = await encrypt(data, 'pw');
  blob[ENCRYPTION_OVERHEAD] = blob[ENCRYPTION_OVERHEAD]! ^ 0xff;
  await assert.rejects(() => decrypt(blob, 'pw'), DecryptionError);
});

test('too-short blob throws DecryptionError', async () => {
  await assert.rejects(() => decrypt(new Uint8Array(10), 'pw'), DecryptionError);
});

test('salt and IV are fresh per call', async () => {
  const a = await encrypt(data, 'pw');
  const b = await encrypt(data, 'pw');
  assert.notDeepEqual(a.subarray(0, 28), b.subarray(0, 28));
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/crypto.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/crypto.ts`:

```ts
/**
 * AES-256-GCM with PBKDF2-HMAC-SHA256 key derivation via Web Crypto.
 * Blob layout matches lib/core/services/encryption_service.dart:
 *   salt(16) | iv(12) | ciphertext | tag(16)
 * (SubtleCrypto appends the GCM tag to the ciphertext, which is exactly
 * this layout — no rearranging needed.)
 */

const SALT_SIZE = 16;
const IV_SIZE = 12;
const TAG_SIZE = 16;
const PBKDF2_ITERATIONS = 100000;

export const ENCRYPTION_OVERHEAD = SALT_SIZE + IV_SIZE + TAG_SIZE;

export class DecryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DecryptionError';
  }
}

async function deriveKey(password: string, salt: Uint8Array): Promise<CryptoKey> {
  // The Dart implementation trims the password before UTF-8 encoding.
  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password.trim()),
    'PBKDF2',
    false,
    ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

export async function encrypt(data: Uint8Array, password: string): Promise<Uint8Array> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_SIZE));
  const iv = crypto.getRandomValues(new Uint8Array(IV_SIZE));
  const key = await deriveKey(password, salt);
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv, tagLength: TAG_SIZE * 8 }, key, data),
  );
  const out = new Uint8Array(SALT_SIZE + IV_SIZE + ciphertext.length);
  out.set(salt, 0);
  out.set(iv, SALT_SIZE);
  out.set(ciphertext, SALT_SIZE + IV_SIZE);
  return out;
}

export async function decrypt(blob: Uint8Array, password: string): Promise<Uint8Array> {
  if (blob.length < ENCRYPTION_OVERHEAD) {
    throw new DecryptionError(
      `Data too short to be encrypted: ${blob.length} bytes (minimum: ${ENCRYPTION_OVERHEAD})`,
    );
  }
  const salt = blob.subarray(0, SALT_SIZE);
  const iv = blob.subarray(SALT_SIZE, SALT_SIZE + IV_SIZE);
  const ciphertext = blob.subarray(SALT_SIZE + IV_SIZE);
  const key = await deriveKey(password, salt);
  try {
    return new Uint8Array(
      await crypto.subtle.decrypt({ name: 'AES-GCM', iv, tagLength: TAG_SIZE * 8 }, key, ciphertext),
    );
  } catch {
    throw new DecryptionError('Decryption failed: wrong password or corrupted data');
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (21 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/crypto.ts webapp/test/crypto.test.ts
git commit -m "feat(webapp): AES-256-GCM + PBKDF2 matching Dart blob layout"
```

---

### Task 5: GZIP wrappers

**Files:**
- Create: `webapp/src/gzip.ts`
- Test: `webapp/test/gzip.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `gzipCompress(data: Uint8Array): Promise<Uint8Array>`, `gzipDecompress(data: Uint8Array): Promise<Uint8Array>`, `isGzip(data: Uint8Array): boolean`

- [ ] **Step 1: Write the failing test**

`webapp/test/gzip.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gzipCompress, gzipDecompress, isGzip } from '../src/gzip.js';

test('gzip round-trip', async () => {
  const data = new TextEncoder().encode('hello world '.repeat(100));
  const compressed = await gzipCompress(data);
  assert.ok(compressed.length < data.length);
  assert.ok(isGzip(compressed));
  assert.deepEqual(await gzipDecompress(compressed), data);
});

test('isGzip detects magic bytes', () => {
  assert.ok(isGzip(new Uint8Array([0x1f, 0x8b, 0x08])));
  assert.ok(!isGzip(new Uint8Array([0x50, 0x4b])));
  assert.ok(!isGzip(new Uint8Array(1)));
});

test('gzipDecompress rejects garbage', async () => {
  await assert.rejects(() => gzipDecompress(new Uint8Array([1, 2, 3, 4])));
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/gzip.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/gzip.ts`:

```ts
/** GZIP via web-native CompressionStream/DecompressionStream (browser + Node >= 18). */

async function pipe(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([data as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}

export function gzipCompress(data: Uint8Array): Promise<Uint8Array> {
  return pipe(data, new CompressionStream('gzip'));
}

export function gzipDecompress(data: Uint8Array): Promise<Uint8Array> {
  return pipe(data, new DecompressionStream('gzip'));
}

export function isGzip(data: Uint8Array): boolean {
  return data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (24 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/gzip.ts webapp/test/gzip.test.ts
git commit -m "feat(webapp): gzip wrappers over CompressionStream"
```

---

### Task 6: Archive/restore pipeline

**Files:**
- Create: `webapp/src/pipeline.ts`
- Test: `webapp/test/pipeline.test.ts`

**Interfaces:**
- Consumes: `createChunks`/`assembleChunks` (Task 3), `encrypt`/`decrypt`/`DecryptionError` (Task 4), `gzipCompress`/`gzipDecompress` (Task 5), `Chunk`/`FLAG_COMPRESSED`/`FLAG_ENCRYPTED` (Task 2).
- Produces:
  - `archive(data: Uint8Array, options: ArchiveOptions): Promise<Chunk[]>` where `interface ArchiveOptions { payloadSize: number; compress?: boolean; password?: string; archiveId?: Uint8Array }`
  - `restore(chunks: Chunk[], password?: string): Promise<Uint8Array>`

- [ ] **Step 1: Write the failing test**

`webapp/test/pipeline.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archive, restore } from '../src/pipeline.js';
import { FLAG_COMPRESSED, FLAG_ENCRYPTED } from '../src/chunk.js';
import { DecryptionError } from '../src/crypto.js';

const compressible = new TextEncoder().encode('abcdefgh'.repeat(200));
const random = crypto.getRandomValues(new Uint8Array(300));

test('plain archive/restore', async () => {
  const chunks = await archive(random, { payloadSize: 100 });
  assert.ok(chunks.every((c) => c.flags === 0));
  assert.deepEqual(await restore(chunks), random);
});

test('compressed archive sets flag and restores', async () => {
  const chunks = await archive(compressible, { payloadSize: 100, compress: true });
  assert.ok(chunks.every((c) => (c.flags & FLAG_COMPRESSED) !== 0));
  assert.deepEqual(await restore(chunks), compressible);
});

test('compression is skipped when it does not shrink the data', async () => {
  const chunks = await archive(random, { payloadSize: 100, compress: true });
  assert.ok(chunks.every((c) => (c.flags & FLAG_COMPRESSED) === 0));
  assert.deepEqual(await restore(chunks), random);
});

test('encrypted archive round-trips and demands the password', async () => {
  const chunks = await archive(random, { payloadSize: 100, password: 'pw' });
  assert.ok(chunks.every((c) => (c.flags & FLAG_ENCRYPTED) !== 0));
  assert.deepEqual(await restore(chunks, 'pw'), random);
  await assert.rejects(() => restore(chunks), DecryptionError);
  await assert.rejects(() => restore(chunks, 'nope'), DecryptionError);
});

test('compressed + encrypted archive round-trips', async () => {
  const chunks = await archive(compressible, { payloadSize: 100, compress: true, password: 'pw' });
  assert.ok(chunks.every((c) => c.flags === (FLAG_COMPRESSED | FLAG_ENCRYPTED)));
  assert.deepEqual(await restore(chunks, 'pw'), compressible);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/pipeline.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/pipeline.ts`:

```ts
/**
 * Archive: data -> (gzip if it shrinks) -> (encrypt if password) -> chunks.
 * Restore: chunks -> assemble -> (decrypt) -> (gunzip) -> data.
 * Mirrors the flag semantics of the Flutter ArchiveNotifier flow.
 */

import { FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from './chunk.js';
import { assembleChunks, createChunks } from './chunker.js';
import { decrypt, DecryptionError, encrypt } from './crypto.js';
import { gzipCompress, gzipDecompress } from './gzip.js';

export interface ArchiveOptions {
  payloadSize: number;
  compress?: boolean;
  password?: string;
  archiveId?: Uint8Array;
}

export async function archive(data: Uint8Array, options: ArchiveOptions): Promise<Chunk[]> {
  let payload = data;
  let flags = 0;
  if (options.compress) {
    const compressed = await gzipCompress(data);
    if (compressed.length < data.length) {
      payload = compressed;
      flags |= FLAG_COMPRESSED;
    }
  }
  if (options.password !== undefined) {
    payload = await encrypt(payload, options.password);
    flags |= FLAG_ENCRYPTED;
  }
  return createChunks(payload, options.payloadSize, flags, options.archiveId);
}

export async function restore(chunks: Chunk[], password?: string): Promise<Uint8Array> {
  let data = assembleChunks(chunks);
  const flags = chunks[0]!.flags;
  if ((flags & FLAG_ENCRYPTED) !== 0) {
    if (password === undefined) {
      throw new DecryptionError('Archive is encrypted; password required');
    }
    data = await decrypt(data, password);
  }
  if ((flags & FLAG_COMPRESSED) !== 0) {
    data = await gzipDecompress(data);
  }
  return data;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (29 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/pipeline.ts webapp/test/pipeline.test.ts
git commit -m "feat(webapp): archive/restore pipeline with flag semantics"
```

---

### Task 7: Transport interface, mock transport, end-to-end test

**Files:**
- Create: `webapp/src/transport/transport.ts`
- Create: `webapp/src/transport/mock-transport.ts`
- Test: `webapp/test/transport.test.ts`

**Interfaces:**
- Consumes: `archive`/`restore` (Task 6), `encodeChunk`/`decodeChunk` (Task 2).
- Produces:
  - `interface Transport { readonly name: string; connect(): Promise<void>; disconnect(): Promise<void>; detectCapacity(): Promise<number>; writeChunk(bytes: Uint8Array): Promise<void>; readChunk(): Promise<Uint8Array> }`
  - `class MockTransport implements Transport` with extras `presentTag(index: number): void` and `get tagCount(): number`

- [ ] **Step 1: Write the failing test**

`webapp/test/transport.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, TOTAL_OVERHEAD, type Chunk } from '../src/chunk.js';

test('mock transport stores and returns chunk bytes', async () => {
  const t = new MockTransport(128);
  await t.connect();
  assert.equal(await t.detectCapacity(), 128);
  await t.writeChunk(new Uint8Array([1, 2, 3]));
  t.presentTag(0);
  assert.deepEqual(await t.readChunk(), new Uint8Array([1, 2, 3]));
});

test('mock transport rejects oversized chunk and empty slot', async () => {
  const t = new MockTransport(16);
  await assert.rejects(() => t.writeChunk(new Uint8Array(17)), RangeError);
  t.presentTag(5);
  await assert.rejects(() => t.readChunk(), RangeError);
});

test('end-to-end: archive -> tags -> shuffled scan -> restore', async () => {
  const original = crypto.getRandomValues(new Uint8Array(500));
  const t = new MockTransport(256);
  const payloadSize = 256 - TOTAL_OVERHEAD;

  const chunks = await archive(original, { payloadSize, compress: true, password: 'e2e-pw' });
  for (const c of chunks) await t.writeChunk(encodeChunk(c));
  assert.equal(t.tagCount, chunks.length);

  const scanned: Chunk[] = [];
  const order = [...Array(t.tagCount).keys()].reverse(); // scan in reverse order
  for (const i of order) {
    t.presentTag(i);
    scanned.push(decodeChunk(await t.readChunk()));
  }
  assert.deepEqual(await restore(scanned, 'e2e-pw'), original);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/mock-transport.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/transport/transport.ts`:

```ts
/**
 * A Transport moves serialized NFAR chunk bytes to/from physical media:
 * NFC tags via the phone (Web NFC), or Mifare Classic cards via a
 * Chameleon Ultra over Web Bluetooth / Web Serial.
 */
export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Usable bytes on the currently presented tag/card. */
  detectCapacity(): Promise<number>;
  writeChunk(bytes: Uint8Array): Promise<void>;
  readChunk(): Promise<Uint8Array>;
}
```

`webapp/src/transport/mock-transport.ts`:

```ts
import type { Transport } from './transport.js';

/** In-memory bank of "tags" for tests and demos. Each writeChunk fills the next tag. */
export class MockTransport implements Transport {
  readonly name = 'mock';
  private readonly tags: Uint8Array[] = [];
  private presented = 0;

  constructor(private readonly capacity = 512) {}

  async connect(): Promise<void> {}
  async disconnect(): Promise<void> {}

  async detectCapacity(): Promise<number> {
    return this.capacity;
  }

  presentTag(index: number): void {
    this.presented = index;
  }

  get tagCount(): number {
    return this.tags.length;
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    if (bytes.length > this.capacity) {
      throw new RangeError(`Chunk (${bytes.length} B) exceeds tag capacity (${this.capacity} B)`);
    }
    this.tags.push(bytes.slice());
  }

  async readChunk(): Promise<Uint8Array> {
    const tag = this.tags[this.presented];
    if (tag === undefined) {
      throw new RangeError(`No tag at index ${this.presented}`);
    }
    return tag.slice();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (32 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/transport/transport.ts webapp/src/transport/mock-transport.ts webapp/test/transport.test.ts
git commit -m "feat(webapp): transport interface, mock transport, e2e round trip"
```

---

### Task 8: Chameleon Ultra BLE transport stub

**Files:**
- Create: `webapp/src/transport/chameleon-ble.ts`
- Test: `webapp/test/chameleon-ble.test.ts`

**Interfaces:**
- Consumes: `Transport` (Task 7).
- Produces:
  - `interface ChameleonUltraLike { connect(): Promise<void>; disconnect(): Promise<void>; isConnected(): boolean }` — the minimal SDK surface the stub delegates to
  - `class ChameleonBleTransport implements Transport` — constructor takes a `ChameleonUltraLike`; `detectCapacity()` returns 752; `writeChunk`/`readChunk` throw `NotImplementedError`
  - `class NotImplementedError extends Error`

- [ ] **Step 1: Write the failing test**

`webapp/test/chameleon-ble.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChameleonBleTransport, NotImplementedError, type ChameleonUltraLike } from '../src/transport/chameleon-ble.js';

function fakeDevice(): ChameleonUltraLike & { connected: boolean } {
  return {
    connected: false,
    async connect() { this.connected = true; },
    async disconnect() { this.connected = false; },
    isConnected() { return this.connected; },
  };
}

test('delegates connect/disconnect to the SDK device', async () => {
  const device = fakeDevice();
  const t = new ChameleonBleTransport(device);
  await t.connect();
  assert.ok(device.connected);
  await t.disconnect();
  assert.ok(!device.connected);
});

test('reports Mifare Classic 1K usable capacity', async () => {
  const t = new ChameleonBleTransport(fakeDevice());
  assert.equal(await t.detectCapacity(), 752);
});

test('block-mapping operations are explicit stubs', async () => {
  const t = new ChameleonBleTransport(fakeDevice());
  await assert.rejects(() => t.writeChunk(new Uint8Array(16)), NotImplementedError);
  await assert.rejects(() => t.readChunk(), NotImplementedError);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: FAIL — TS2307: Cannot find module '../src/transport/chameleon-ble.js'.

- [ ] **Step 3: Write minimal implementation**

`webapp/src/transport/chameleon-ble.ts`:

```ts
import type { Transport } from './transport.js';

/**
 * Minimal surface of the chameleon-ultra.js SDK (MIT) this transport needs.
 * Intended wiring in the browser:
 *   const ultra = new ChameleonUltra()
 *   ultra.use(new WebbleAdapter())   // or WebserialAdapter for USB
 *   new ChameleonBleTransport(ultra)
 * The real SDK instance satisfies this interface structurally.
 */
export interface ChameleonUltraLike {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;
}

export class NotImplementedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotImplementedError';
  }
}

/**
 * Transport stub for the Chameleon Ultra over Web Bluetooth.
 * Chunk <-> Mifare Classic block mapping is out of scope for this prototype
 * (see the design spec); read/write throw until that layout is designed.
 */
export class ChameleonBleTransport implements Transport {
  readonly name = 'chameleon-ble';

  constructor(private readonly device: ChameleonUltraLike) {}

  async connect(): Promise<void> {
    if (!this.device.isConnected()) await this.device.connect();
  }

  async disconnect(): Promise<void> {
    if (this.device.isConnected()) await this.device.disconnect();
  }

  async detectCapacity(): Promise<number> {
    // Mifare Classic 1K: 64 blocks x 16 B, minus 16 sector trailers and
    // the manufacturer block -> 47 usable blocks = 752 bytes.
    return 752;
  }

  async writeChunk(_bytes: Uint8Array): Promise<void> {
    throw new NotImplementedError('Mifare Classic block mapping is not implemented in this prototype');
  }

  async readChunk(): Promise<Uint8Array> {
    throw new NotImplementedError('Mifare Classic block mapping is not implemented in this prototype');
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (35 tests total).

- [ ] **Step 5: Commit**

```bash
git add webapp/src/transport/chameleon-ble.ts webapp/test/chameleon-ble.test.ts
git commit -m "feat(webapp): Chameleon Ultra BLE transport stub"
```

---

### Task 9: Dart → TS interop fixtures

**Files:**
- Create: `tool/generate_web_fixtures.dart`
- Create: `webapp/test/fixtures/dart_generated.json` (generated, committed)
- Test: `webapp/test/interop-dart.test.ts`

**Interfaces:**
- Consumes: the app's `lib/core` services (Dart side); `decodeChunk`/`encodeChunk`, `assembleChunks`, `decrypt`, `gzipDecompress`, `crc32`, `fromHex`/`toHex` (TS side).
- Produces: fixture JSON with fields `payloadSize: number`, `original: hex`, `chunks: hex[]`, `password: string`, `encrypted: hex`, `gzipped: hex`, `crc32OfOriginal: number`.

- [ ] **Step 1: Write the Dart fixture generator**

`tool/generate_web_fixtures.dart`:

```dart
/// Generates interop fixtures for the webapp TS core using the app's own
/// production services. Run from the repo root:
///   dart run tool/generate_web_fixtures.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/core/services/chunker_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final original = Uint8List.fromList(List.generate(200, (i) => i % 251));
  // Deliberately padded: proves both sides trim before key derivation.
  const password = '  interop-password  ';

  final result = ChunkerService.instance.createChunksWithSize(
    data: original,
    payloadSize: 64,
  );
  final encrypted = EncryptionService.instance.encrypt(original, password);
  final gzipped = CompressionService.instance.compress(original);
  final crc = ChecksumService.instance.calculate(original);

  final json = const JsonEncoder.withIndent('  ').convert({
    'payloadSize': 64,
    'original': hexOf(original),
    'chunks': result.chunks.map((c) => hexOf(c.toBytes())).toList(),
    'password': password,
    'encrypted': hexOf(encrypted),
    'gzipped': hexOf(gzipped),
    'crc32OfOriginal': crc,
  });

  final out = File('webapp/test/fixtures/dart_generated.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$json\n');
  stdout.writeln('Wrote ${out.path}');
}
```

- [ ] **Step 2: Generate the fixture**

```bash
cd /home/mezinster/nfcarchiver && dart run tool/generate_web_fixtures.dart
```

Expected: `Wrote webapp/test/fixtures/dart_generated.json`. Inspect: 4 chunks, hex fields non-empty.

- [ ] **Step 3: Write the failing TS test**

`webapp/test/interop-dart.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assembleChunks } from '../src/chunker.js';
import { decodeChunk, encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { decrypt } from '../src/crypto.js';
import { gzipDecompress } from '../src/gzip.js';
import { fromHex } from './hex.js';

interface Fixture {
  payloadSize: number;
  original: string;
  chunks: string[];
  password: string;
  encrypted: string;
  gzipped: string;
  crc32OfOriginal: number;
}

// dist/test/ -> ../../test/fixtures (fixtures are not compiled by tsc)
const fixturePath = join(dirname(fileURLToPath(import.meta.url)), '../../test/fixtures/dart_generated.json');
const fixture: Fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const original = fromHex(fixture.original);

test('TS decodes Dart-serialized chunks and re-encodes byte-identically', () => {
  for (const hex of fixture.chunks) {
    const bytes = fromHex(hex);
    const chunk = decodeChunk(bytes);
    assert.deepEqual(encodeChunk(chunk), bytes);
  }
});

test('TS reassembles Dart chunks to the original bytes', () => {
  const chunks = fixture.chunks.map((h) => decodeChunk(fromHex(h)));
  assert.deepEqual(assembleChunks(chunks), original);
});

test('TS decrypts a Dart-encrypted blob (incl. password trimming)', async () => {
  assert.deepEqual(await decrypt(fromHex(fixture.encrypted), fixture.password), original);
});

test('TS decompresses Dart gzip output', async () => {
  assert.deepEqual(await gzipDecompress(fromHex(fixture.gzipped)), original);
});

test('TS CRC-32 matches Dart over the original data', () => {
  assert.equal(crc32(original), fixture.crc32OfOriginal);
});
```

- [ ] **Step 4: Run test to verify it passes**

(No failing-first step here: the implementation under test already exists; this test is the interop gate itself.)

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (40 tests total). If any interop test fails, the TS port has a real compatibility bug — fix the TS side, never the fixture.

- [ ] **Step 5: Commit**

```bash
git add tool/generate_web_fixtures.dart webapp/test/fixtures/dart_generated.json webapp/test/interop-dart.test.ts
git commit -m "test(webapp): Dart->TS interop fixtures prove byte compatibility"
```

---

### Task 10: TS → Dart verification

**Files:**
- Create: `webapp/test/write_ts_fixtures.ts`
- Create: `tool/verify_web_fixtures.dart`
- Create: `webapp/test/fixtures/ts_generated.json` (generated, committed)

**Interfaces:**
- Consumes: `createChunks`, `encodeChunk`, `encrypt`, `gzipCompress`, `toHex` (TS); `Chunk.fromBytes`, `ChunkerService.assembleChunks`, `EncryptionService.decrypt`, `CompressionService.decompress` (Dart).
- Produces: `ts_generated.json` with the same field names as `dart_generated.json`; `dart run tool/verify_web_fixtures.dart` exits 0 on success, 1 on mismatch, 2 if the fixture file is missing.

- [ ] **Step 1: Write the TS fixture writer**

`webapp/test/write_ts_fixtures.ts`:

```ts
/** Writes TS-generated interop fixtures for tool/verify_web_fixtures.dart. Run: npm run fixtures */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createChunks } from '../src/chunker.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { encrypt } from '../src/crypto.js';
import { gzipCompress } from '../src/gzip.js';
import { toHex } from './hex.js';

const original = new Uint8Array(200).map((_, i) => i % 251);
const password = '  interop-password  ';

const chunks = createChunks(original, 64);
const encrypted = await encrypt(original, password);
const gzipped = await gzipCompress(original);

const fixture = {
  payloadSize: 64,
  original: toHex(original),
  chunks: chunks.map((c) => toHex(encodeChunk(c))),
  password,
  encrypted: toHex(encrypted),
  gzipped: toHex(gzipped),
  crc32OfOriginal: crc32(original),
};

const outPath = join(dirname(fileURLToPath(import.meta.url)), '../../test/fixtures/ts_generated.json');
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(fixture, null, 2) + '\n');
console.log(`Wrote ${outPath}`);
```

- [ ] **Step 2: Generate the TS fixture**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm run fixtures
```

Expected: `Wrote .../webapp/test/fixtures/ts_generated.json`.

- [ ] **Step 3: Write the Dart verifier**

`tool/verify_web_fixtures.dart`:

```dart
/// Verifies TS-generated fixtures decode with the app's production services.
/// Run from the repo root (after `npm run fixtures` in webapp/):
///   dart run tool/verify_web_fixtures.dart
/// Exits 0 on success, 1 on mismatch, 2 if the fixture file is missing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/core/services/chunker_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';

Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

var failures = 0;

void check(bool condition, String label) {
  if (condition) {
    stdout.writeln('OK   $label');
  } else {
    stderr.writeln('FAIL $label');
    failures++;
  }
}

void main() {
  final file = File('webapp/test/fixtures/ts_generated.json');
  if (!file.existsSync()) {
    stderr.writeln('Missing ${file.path} — run `npm run fixtures` in webapp/ first');
    exit(2);
  }
  final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final original = fromHex(j['original'] as String);

  final chunks = (j['chunks'] as List)
      .map((h) => Chunk.fromBytes(fromHex(h as String)))
      .toList();
  final assembled = ChunkerService.instance.assembleChunks(chunks);
  check(bytesEqual(assembled, original), 'chunk decode + reassembly');

  final decrypted = EncryptionService.instance.decrypt(
    fromHex(j['encrypted'] as String),
    j['password'] as String,
  );
  check(bytesEqual(decrypted, original), 'AES-256-GCM decryption (trimmed password)');

  final gunzipped =
      CompressionService.instance.decompress(fromHex(j['gzipped'] as String));
  check(bytesEqual(gunzipped, original), 'gzip decompression');

  check(
    ChecksumService.instance.calculate(original) == j['crc32OfOriginal'],
    'CRC-32 agreement',
  );

  if (failures > 0) {
    stderr.writeln('$failures verification(s) failed');
    exit(1);
  }
  stdout.writeln('All TS fixtures verified against Dart core');
}
```

- [ ] **Step 4: Run the verifier**

```bash
cd /home/mezinster/nfcarchiver && dart run tool/verify_web_fixtures.dart
```

Expected:

```
OK   chunk decode + reassembly
OK   AES-256-GCM decryption (trimmed password)
OK   gzip decompression
OK   CRC-32 agreement
All TS fixtures verified against Dart core
```

If any line FAILs, the TS port has a compatibility bug — fix the TS side and regenerate `ts_generated.json`.

- [ ] **Step 5: Run the full TS suite once more (regression gate)**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm test
```

Expected: PASS (40 tests).

- [ ] **Step 6: Commit**

```bash
git add webapp/test/write_ts_fixtures.ts webapp/test/fixtures/ts_generated.json tool/verify_web_fixtures.dart
git commit -m "test(webapp): TS->Dart verification closes the interop loop"
```

---

## Completion Criteria

- `npm test` in `webapp/` passes (40 tests) on Node LTS.
- `dart run tool/verify_web_fixtures.dart` prints all OK and exits 0.
- `flutter analyze` still passes (the two `tool/` scripts must be lint-clean).
- No runtime dependencies in `webapp/package.json`.
