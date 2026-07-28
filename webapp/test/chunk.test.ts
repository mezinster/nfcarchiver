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
