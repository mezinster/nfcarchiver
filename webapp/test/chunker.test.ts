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
