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
  originalText: string;
  gzippedText: string;
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

test('TS decompresses Dart gzip output (compressed data)', async () => {
  const originalText = fromHex(fixture.originalText);
  const gzippedText = fromHex(fixture.gzippedText);
  assert.deepEqual(await gzipDecompress(gzippedText), originalText);
  // Sanity check: proves the block is actually compressed, not stored.
  assert.ok(gzippedText.length < originalText.length);
});

test('TS CRC-32 matches Dart over the original data', () => {
  assert.equal(crc32(original), fixture.crc32OfOriginal);
});
