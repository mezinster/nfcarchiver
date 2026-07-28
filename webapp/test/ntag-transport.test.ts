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
