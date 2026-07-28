# Web App NFAR Core — Design

**Date:** 2026-07-27
**Status:** Draft for review
**Location:** `webapp/` (new top-level directory in this repo)

## Goal

Prototype the platform-agnostic core of a browser-based NFC Archiver companion:
a TypeScript port of the NFAR v1 pipeline (chunk codec, chunker/assembler,
CRC-32, AES-256-GCM + PBKDF2, GZIP) that is **provably byte-compatible** with
the Dart implementation in `lib/core/`, plus a transport abstraction shaped for
the Chameleon Ultra over Web Bluetooth (`chameleon-ultra.js`, MIT).

An archive written by the Flutter app must be restorable by the web core and
vice versa.

## Non-Goals (this prototype)

- No UI / PWA shell, no hosting setup.
- No real BLE hardware integration — the Chameleon transport is a typed stub
  matching the `chameleon-ultra.js` adapter API; a `MockTransport` provides the
  demonstrable end-to-end round trip.
- No Web NFC, no Web Serial implementation (interface leaves room for both).
- No Mifare Classic block-layout design (that is transport-payload mapping work
  for the next iteration).

## Compatibility Contract

Facts pinned from the Dart source; the TS port must match each exactly.

| Aspect | Requirement | Dart source |
|---|---|---|
| Header | 28 bytes: `NFAR` magic, version `0x01`, flags, 16-byte archive UUID, uint16 totalChunks / chunkIndex / payloadSize, all big-endian; payload; CRC-32 (4 bytes) | `lib/core/constants/nfar_format.dart` |
| Flags | bit 0 = GZIP, bit 1 = AES-256-GCM | `NfarFlags` |
| CRC-32 | Reflected, poly `0xEDB88320`, init/xorout `0xFFFFFFFF` (zlib/IEEE variant), computed over payload only | `lib/core/services/checksum_service.dart` |
| Encryption | `salt(16) ‖ iv(12) ‖ ciphertext ‖ tag(16)`; AES-256-GCM, 128-bit tag, no AAD; PBKDF2-HMAC-SHA256, 100 000 iterations, 32-byte key; **password is `trim()`ed** then UTF-8 encoded | `lib/core/services/encryption_service.dart` |
| GZIP | Standard gzip container. Byte-identity is **not** required (deflate output is implementation-specific); cross-decompression is: Dart must decompress TS output and vice versa | `lib/core/services/compression_service.dart` |
| Assembly | Chunks in any order; validate same archive ID, consistent totalChunks, no missing/duplicate indices, per-chunk CRC | `lib/core/services/chunker_service.dart` |
| Limits | Max 65 535 chunks, max 65 535-byte payload | `NfarLimits` |

Byte-identity is required for: chunk serialization (given identical inputs) and
the encrypted-blob layout. Randomized elements (UUID, salt, IV) make whole-blob
identity impossible across runs; compatibility is proven by cross-language
decode/decrypt instead.

## Architecture

```
webapp/
  package.json          # zero runtime deps; dev deps: typescript only
  tsconfig.json
  src/
    crc32.ts            # table-driven reflected CRC-32
    chunk.ts            # Chunk type + encodeChunk()/decodeChunk()
    chunker.ts          # createChunks()/assembleChunks() + validation
    crypto.ts           # encrypt()/decrypt() via crypto.subtle (PBKDF2 + AES-GCM)
    gzip.ts             # CompressionStream/DecompressionStream wrappers
    pipeline.ts         # archive()/restore(): compress → encrypt → chunk and inverse
    transport/
      transport.ts      # Transport interface: capacity discovery, writeChunk, readChunk
      mock-transport.ts # in-memory tag bank for tests/demo
      chameleon-ble.ts  # typed stub around chameleon-ultra.js WebbleAdapter API
  test/
    *.test.ts           # node:test, run against tsc output
    fixtures/           # cross-language fixtures (JSON with hex fields)
tool/
  generate_web_fixtures.dart  # Dart → fixtures (uses package:nfc_archiver/core)
  verify_web_fixtures.dart    # verifies TS-generated fixtures decode in Dart
```

The core uses only web-platform globals (`crypto.subtle`, `CompressionStream`,
`DataView`, `crypto.getRandomValues`, `crypto.randomUUID`), which exist in
browsers and Node ≥ 18 — the same files run in a PWA and under `node --test`
with no shims.

## Interfaces (abbreviated)

```ts
interface Chunk {
  archiveId: Uint8Array;   // 16 bytes
  totalChunks: number;
  chunkIndex: number;
  payload: Uint8Array;
  crc32: number;
  flags: number;
}
encodeChunk(c: Chunk): Uint8Array
decodeChunk(bytes: Uint8Array): Chunk          // throws NfarFormatError
createChunks(data, payloadSize, flags): Chunk[]
assembleChunks(chunks: Chunk[]): Uint8Array    // throws NfarAssemblyError
encrypt(data: Uint8Array, password: string): Promise<Uint8Array>
decrypt(blob: Uint8Array, password: string): Promise<Uint8Array>
gzipCompress(data): Promise<Uint8Array>; gzipDecompress(data): Promise<Uint8Array>

interface Transport {
  readonly name: string;
  connect(): Promise<void>; disconnect(): Promise<void>;
  detectCapacity(): Promise<number>;      // usable bytes on the presented tag
  writeChunk(bytes: Uint8Array): Promise<void>;
  readChunk(): Promise<Uint8Array>;
}
```

Errors are typed classes mirroring the Dart `FormatException`/`ArgumentError`
cases (bad magic, bad version, short data, CRC mismatch, missing/duplicate
chunks, wrong password).

## Testing Strategy

1. **Unit tests (Node ≥ 18, `node:test`)** — CRC vectors (e.g. `"123456789"` →
   `0xCBF43926`), header round-trips, chunker edge cases (empty payload-final
   chunk, max chunks), crypto round-trip, wrong-password rejection, gzip
   round-trip, mock-transport end-to-end archive→restore.
2. **Dart → TS fixtures** — `tool/generate_web_fixtures.dart` emits
   `webapp/test/fixtures/dart_generated.json`: a serialized multi-chunk archive
   (known payload), an encrypted blob (known password), a gzipped blob, and CRC
   values. TS tests must decode, decrypt, and reassemble to the exact original
   bytes.
3. **TS → Dart verification** — TS test run writes `ts_generated.json`;
   `tool/verify_web_fixtures.dart` decodes/decrypts it with the app's own
   `lib/core` services and exits non-zero on any mismatch.

Both fixture tools are plain `dart run` scripts inside this package so they use
the production code paths, not reimplementations.

## Environment Note

Installed Node is v14 (lacks `crypto.subtle` global and `CompressionStream`).
Prerequisite: `nvm install --lts` (Node 24) for running tests; the nvm default
alias stays at 14.

## Risks / Open Points

- **PBKDF2 100k in the browser** is fast under native `crypto.subtle` (~tens of
  ms), no worker needed for the prototype.
- **`chameleon-ultra.js` API drift** — the stub is written against its published
  adapter surface but not exercised against hardware in this prototype.
- **Payload sizing for Mifare Classic** differs from NDEF overhead math
  (`NfcTagType.maxPayloadSize`); deferred to transport-mapping work.
- Unrelated bug noticed during design: `CompressionService._ln()`
  (`lib/core/services/compression_service.dart:111`) is a placeholder returning
  `x.toString().length`, so `estimateCompressionRatio()` is meaningless. Not in
  scope here; fix separately in the Flutter app.
