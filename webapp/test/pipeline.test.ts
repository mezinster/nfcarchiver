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
