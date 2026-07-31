import { test } from 'node:test';
import assert from 'node:assert/strict';
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
  expected: { capacityBytes: number; maxChunkPayload: number },
): void {
  const uidA = new Uint8Array([0xa1, 0xa2, 0xa3, 0xa4]);

  test(`${name}: awaitTag returns uid + ${expected.capacityBytes}-byte capacity`, async () => {
    const { transport, tap } = make();
    await transport.connect();
    tap(uidA);
    const tag = await transport.awaitTag({ timeoutMs: 1000 });
    assert.equal(toHex(tag.uid), toHex(uidA));
    assert.equal(tag.capacityBytes, expected.capacityBytes);
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
    const full = chunkBytes(expected.maxChunkPayload);
    await transport.writeChunk(full);
    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    assert.deepEqual(await transport.readChunk(), full);

    tap(uidA);
    await transport.awaitTag({ timeoutMs: 1000 });
    await assert.rejects(() => transport.writeChunk(new Uint8Array(expected.capacityBytes + 1)), CardCapacityError);
  });

  test(`${name}: awaitTag with no tag rejects TagTimeoutError`, async () => {
    const { transport } = make();
    await transport.connect();
    await assert.rejects(() => transport.awaitTag({ timeoutMs: 20 }), /No tag|timeout/i);
  });
}
