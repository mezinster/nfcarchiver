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
