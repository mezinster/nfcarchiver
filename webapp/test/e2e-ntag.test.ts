import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archive, restore } from '../src/pipeline.js';
import { encodeChunk, decodeChunk, type Chunk } from '../src/chunk.js';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType, chunkPayloadForCapacity } from '../src/nfc/type2.js';

test('archive to NTAG215 tags via AutoTransport, then restore byte-identical', async () => {
  const original = new TextEncoder().encode('ntag payload '.repeat(120));
  const device = new FakeChameleon();
  const transport = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await transport.connect();

  // Size chunks to the tag's real per-card NDEF capacity read from its CC (496 B
  // for NTAG215, not the 504 B raw memory) — mirroring the app's auto-rechunk.
  const probeUid = new Uint8Array([0x04, 0, 0, 0, 0, 0, 0xff]);
  device.placeNtag(probeUid, NtagType.NTAG215);
  const payloadSize = (await transport.awaitTag()).maxChunkPayload;
  assert.equal(payloadSize, chunkPayloadForCapacity(496));

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
