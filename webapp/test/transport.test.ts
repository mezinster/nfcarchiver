import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { archive, restore } from '../src/pipeline.js';
import {
  decodeChunk,
  encodeChunk,
  TOTAL_OVERHEAD,
  FLAG_COMPRESSED,
  FLAG_ENCRYPTED,
  type Chunk,
} from '../src/chunk.js';

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
  // Create compressible data: structured text that gzip compresses effectively
  const words = [];
  for (let i = 0; i < 400; i++) words.push(`chunk-${i}-payload`);
  const original = new TextEncoder().encode(words.join(' '));

  const t = new MockTransport(256);
  const payloadSize = 256 - TOTAL_OVERHEAD;

  const chunks = await archive(original, { payloadSize, compress: true, password: 'e2e-pw' });

  // Verify both compression and encryption flags are set
  assert.ok(chunks.every((c) => c.flags === (FLAG_COMPRESSED | FLAG_ENCRYPTED)));
  // Verify multiple chunks are produced (compression + chunking)
  assert.ok(chunks.length >= 2);

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
