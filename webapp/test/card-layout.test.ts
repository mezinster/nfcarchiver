import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  USABLE_BLOCK_INDEXES, CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE, BLOCK_SIZE,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks,
  CardCapacityError,
} from '../src/mifare/card-layout.js';
import { encodeChunk, NfarFormatError, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

function chunkOfPayload(n: number): Uint8Array {
  const payload = new Uint8Array(n).map((_, i) => (i * 3) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).map((_, i) => i + 1),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  };
  return encodeChunk(c);
}

test('exactly 47 usable blocks, excluding block 0 and every sector trailer', () => {
  assert.equal(USABLE_BLOCK_INDEXES.length, 47);
  assert.equal(CARD_CAPACITY_BYTES, USABLE_BLOCK_INDEXES.length * BLOCK_SIZE);
  assert.ok(!USABLE_BLOCK_INDEXES.includes(0));
  for (const b of USABLE_BLOCK_INDEXES) assert.notEqual(b % 4, 3, `block ${b} is a sector trailer`);
  assert.deepEqual(USABLE_BLOCK_INDEXES.slice(0, 5), [1, 2, 4, 5, 6]);
  assert.equal(USABLE_BLOCK_INDEXES.at(-1), 62);
});

test('chunkToBlocks maps bytes onto usable blocks in order, zero-padding the last', () => {
  const bytes = chunkOfPayload(20); // 52 total -> ceil(52/16)=4 blocks
  const blocks = chunkToBlocks(bytes);
  assert.equal(blocks.length, 4);
  assert.deepEqual(blocks.map((b) => b.block), [1, 2, 4, 5]);
  assert.ok(blocks.every((b) => b.data.length === 16));
  // reassembling all block data and trimming reproduces the chunk
  const flat = new Uint8Array(blocks.length * 16);
  blocks.forEach((b, i) => flat.set(b.data, i * 16));
  assert.deepEqual(flat.subarray(0, bytes.length), bytes);
  assert.ok(flat.subarray(bytes.length).every((x) => x === 0)); // padding is zero
});

test('a full 720-byte payload fills all 47 blocks; 721 overflows', () => {
  const full = chunkOfPayload(CARD_PAYLOAD_SIZE); // 752 total
  assert.equal(chunkToBlocks(full).length, 47);
  assert.throws(() => chunkToBlocks(chunkOfPayload(CARD_PAYLOAD_SIZE + 1)), CardCapacityError);
});

test('firstBlockIsNfar detects magic + version', () => {
  const bytes = chunkOfPayload(10);
  assert.ok(firstBlockIsNfar(bytes.subarray(0, 16)));
  const notMagic = bytes.slice(0, 16); notMagic[0] = 0x00;
  assert.ok(!firstBlockIsNfar(notMagic));
  const badVer = bytes.slice(0, 16); badVer[4] = 0x02;
  assert.ok(!firstBlockIsNfar(badVer));
});

test('nfarTotalLength reads payloadSize from the header, rejects non-NFAR', () => {
  const bytes = chunkOfPayload(100); // total 132
  assert.equal(nfarTotalLength(bytes.subarray(0, 28)), 132);
  const bad = bytes.slice(0, 28); bad[0] = 0x00;
  assert.throws(() => nfarTotalLength(bad), NfarFormatError);
});

test('assembleChunkFromBlocks concatenates ordered block data and trims to length', () => {
  const bytes = chunkOfPayload(30); // total 62, 4 blocks
  const blocks = chunkToBlocks(bytes).map((b) => b.data);
  assert.deepEqual(assembleChunkFromBlocks(blocks, bytes.length), bytes);
});
