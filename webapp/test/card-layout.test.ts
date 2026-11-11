import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  USABLE_BLOCK_INDEXES, CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE, BLOCK_SIZE,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks,
  CardCapacityError, USABLE_BLOCK_INDEXES_4K, capacityBytes, payloadSize, usableBlocks,
  sectorOf, isSectorTrailer, firstBlockOfSector, writableCapacity,
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

test('nfarTotalLength rejects a declared length beyond card capacity', () => {
  const bytes = chunkOfPayload(10);
  const header = bytes.slice(0, 28);
  // Corrupt the payloadSize field (bytes 26-27, big-endian) to its max value.
  header[26] = 0xff;
  header[27] = 0xff;
  assert.throws(() => nfarTotalLength(header), NfarFormatError);
});

test('assembleChunkFromBlocks concatenates ordered block data and trims to length', () => {
  const bytes = chunkOfPayload(30); // total 62, 4 blocks
  const blocks = chunkToBlocks(bytes).map((b) => b.data);
  assert.deepEqual(assembleChunkFromBlocks(blocks, bytes.length), bytes);
});

function headerDeclaring(payloadLen: number): Uint8Array {
  const h = chunkOfPayload(10).slice(0, 28);
  new DataView(h.buffer).setUint16(26, payloadLen);
  return h;
}

test('4K constants', () => {
  assert.equal(USABLE_BLOCK_INDEXES_4K.length, 215);
  assert.equal(capacityBytes('4k'), 3440);
  assert.equal(payloadSize('4k'), 3408);
  assert.equal(capacityBytes('1k'), 752);
  assert.equal(payloadSize('1k'), 720);
  assert.deepEqual(USABLE_BLOCK_INDEXES_4K.slice(0, 47), [...USABLE_BLOCK_INDEXES]);
  assert.equal(usableBlocks('1k'), USABLE_BLOCK_INDEXES);
  assert.equal(usableBlocks('4k'), USABLE_BLOCK_INDEXES_4K);
});

test('4K: no block 0, no trailers; 128 and 142 in, 143 out', () => {
  const trailers: number[] = [];
  for (let b = 3; b < 128; b += 4) trailers.push(b);
  for (let b = 143; b < 256; b += 16) trailers.push(b);
  for (const l of [USABLE_BLOCK_INDEXES, USABLE_BLOCK_INDEXES_4K]) {
    assert.ok(!l.includes(0));
    for (const t of trailers) assert.ok(!l.includes(t), `trailer ${t}`);
  }
  assert.ok(USABLE_BLOCK_INDEXES_4K.includes(128));
  assert.ok(USABLE_BLOCK_INDEXES_4K.includes(142));
  assert.ok(!USABLE_BLOCK_INDEXES_4K.includes(143));
});

test('sector helpers', () => {
  assert.equal(sectorOf(127), 31);
  assert.equal(sectorOf(128), 32);
  assert.equal(sectorOf(143), 32);
  assert.equal(sectorOf(144), 33);
  assert.equal(sectorOf(255), 39);
  assert.equal(firstBlockOfSector(33), 144);
  assert.equal(firstBlockOfSector(31), 124);
  assert.ok(isSectorTrailer(127));
  assert.ok(isSectorTrailer(143));
  assert.ok(!isSectorTrailer(142));
});

test('chunkToBlocks sizes', () => {
  const bytesOf = (n: number) => new Uint8Array(n).map((_, i) => i & 0xff);
  const b = bytesOf(752);
  const d = chunkToBlocks(b);
  const k = chunkToBlocks(b, '4k');
  assert.deepEqual(k, d);
  const big = chunkToBlocks(bytesOf(3000), '4k');
  assert.equal(big.length, 188);
  assert.equal(big.at(-1)!.block, USABLE_BLOCK_INDEXES_4K[187]);
  assert.throws(() => chunkToBlocks(bytesOf(753)), CardCapacityError);
  assert.throws(() => chunkToBlocks(bytesOf(3441), '4k'), /4K card holds 3440/);
  assert.throws(() => chunkToBlocks(bytesOf(753)), /1K card holds 752/);
});

test('nfarTotalLength honours size', () => {
  assert.throws(() => nfarTotalLength(headerDeclaring(3000)), NfarFormatError);
  assert.equal(nfarTotalLength(headerDeclaring(3000), '4k'), 3032);
  assert.equal(nfarTotalLength(headerDeclaring(3408), '4k'), 3440);
  assert.throws(() => nfarTotalLength(headerDeclaring(3409), '4k'), NfarFormatError);
});

test('writableCapacity', () => {
  assert.equal(writableCapacity('4k', false), 752);
  assert.equal(writableCapacity('4k', true), 3440);
  assert.equal(writableCapacity('1k', true), 752);
});
