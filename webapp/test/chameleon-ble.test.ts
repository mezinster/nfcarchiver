import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError, CardReadError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';
import { NfarFormatError } from '../src/chunk.js';
import { FakeChameleon } from './fake-chameleon.js';
import { runTransportContract } from './transport-contract.js';
import { encodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { USABLE_BLOCK_INDEXES, CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE, CardCapacityError, chunkToBlocks } from '../src/mifare/card-layout.js';

function chunkBytes(payloadLen: number): Uint8Array {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 5) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).fill(7), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  };
  return encodeChunk(c);
}

runTransportContract('ChameleonBleTransport+FakeChameleon', () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  return { transport, tap: (uid) => device.place(uid) };
}, { capacityBytes: CARD_CAPACITY_BYTES, maxChunkPayload: CARD_PAYLOAD_SIZE });

test('connect delegates to the device; awaitTag polls scanTag', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  assert.ok(device.isConnected());
  const uid = new Uint8Array([1, 2, 3, 4]);
  setTimeout(() => device.place(uid), 5); // tag arrives after a couple polls
  const tag = await transport.awaitTag();
  assert.deepEqual(tag.uid, uid);
  assert.equal(tag.maxChunkPayload, CARD_PAYLOAD_SIZE);
});

test('awaitTag honors AbortSignal', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 5, defaultTimeoutMs: 1000 });
  await transport.connect();
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 10);
  await assert.rejects(() => transport.awaitTag({ signal: ac.signal }), (e: Error) => e.name === 'AbortError');
});

test('writeChunk writes only usable blocks and skips trailers/block 0', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  const uid = new Uint8Array([9, 9, 9, 9]);
  device.place(uid);
  await transport.awaitTag();
  const bytes = chunkBytes(40); // 72 total -> 5 blocks: 1,2,4,5,6
  await transport.writeChunk(bytes);
  // block 0 and trailer block 3 stay zero
  assert.ok(device.blockOf(uid, 0).every((b) => b === 0));
  assert.ok(device.blockOf(uid, 3).every((b) => b === 0));
  // first usable block holds the NFAR magic
  assert.deepEqual(device.blockOf(uid, USABLE_BLOCK_INDEXES[0]!).subarray(0, 4), bytes.subarray(0, 4));
});

test('write-then-verify catches a corrupted block', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  device.place(new Uint8Array([4, 4, 4, 4]));
  await transport.awaitTag();
  device.corruptNextWrite();
  await assert.rejects(() => transport.writeChunk(chunkBytes(30)), WriteVerifyError);
});

test('readChunk rejects a corrupted payloadSize instead of looping past usable blocks', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  const uid = new Uint8Array([8, 8, 8, 8]);
  device.place(uid);
  await transport.awaitTag();
  await transport.writeChunk(chunkBytes(30)); // small valid chunk

  // Corrupt the payloadSize field (chunk-byte offset 26-27), which lives at
  // byte index 10-11 of the second usable block (offset 26 - 16 = 10).
  const secondBlock = USABLE_BLOCK_INDEXES[1]!;
  const corrupted = device.blockOf(uid, secondBlock).slice();
  corrupted[10] = 0xff;
  corrupted[11] = 0xff;
  await device.writeBlock(secondBlock, FACTORY_KEY_A, corrupted);

  device.place(uid); // same card back in the field
  await transport.awaitTag();
  await assert.rejects(() => transport.readChunk(), NfarFormatError);
});

test('non-factory-key card surfaces CardAuthError', async () => {
  const device = new FakeChameleon();
  const uid = new Uint8Array([5, 5, 5, 5]);
  device.defineCard(uid, { keyA: new Uint8Array([1, 2, 3, 4, 5, 6]) });
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await transport.connect();
  device.place(uid);
  await transport.awaitTag();
  await assert.rejects(() => transport.writeChunk(chunkBytes(20)), CardAuthError);
});

// ---- Mifare Classic 4K ------------------------------------------------------

const on = () => true;
const uid4k = new Uint8Array([0x4b, 0x4b, 0x4b, 0x4b]);

async function tap4k(opts: { allow4k?: () => boolean; sectorKeys?: Map<number, Uint8Array> } = {}) {
  const device = new FakeChameleon();
  device.defineCard(uid4k, { sak: 0x38, sectorKeys: opts.sectorKeys });
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200, allow4k: opts.allow4k });
  await transport.connect();
  device.place(uid4k);
  const tag = await transport.awaitTag();
  return { device, transport, tag };
}

test('4K card, switch on: capacity 3440, maxChunkPayload 3408', async () => {
  const { tag } = await tap4k({ allow4k: on });
  assert.equal(tag.capacityBytes, 3440);
  assert.equal(tag.maxChunkPayload, 3408);
});

test('4K card, switch off: capacity 3440 but maxChunkPayload 720', async () => {
  const { tag } = await tap4k();
  assert.equal(tag.capacityBytes, 3440);
  assert.equal(tag.maxChunkPayload, 720);
});

test('4K card, switch on: a 3,000 B payload writes and reads back', async () => {
  const { transport, device } = await tap4k({ allow4k: on });
  const bytes = chunkBytes(3000);
  await transport.writeChunk(bytes);
  assert.deepEqual(await transport.readChunk(), bytes);
  assert.ok(device.blockOf(uid4k, 128).some((b) => b !== 0)); // spilled into the 16-block sectors
});

test('4K card pre-written with a 3,000 B chunk still reads with the switch off', async () => {
  const { transport: writer, device } = await tap4k({ allow4k: on });
  const bytes = chunkBytes(3000);
  await writer.writeChunk(bytes);
  const reader = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await reader.awaitTag();
  assert.equal(await reader.peekIsNfar(), true);
  assert.deepEqual(await reader.readChunk(), bytes);
});

test('4K card, switch off: a chunk over 752 B is refused and nothing is written', async () => {
  const { transport, device } = await tap4k();
  await assert.rejects(() => transport.writeChunk(chunkBytes(3000)), CardCapacityError);
  assert.equal(device.writeCount, 0);
});

test('4K card, switch turned off after the tap: the write is still refused', async () => {
  let flag = true;
  const { transport, device } = await tap4k({ allow4k: () => flag });
  flag = false;
  await assert.rejects(() => transport.writeChunk(chunkBytes(3000)), CardCapacityError);
  assert.equal(device.writeCount, 0);
});

test('4K: sector 33 with a non-factory key fails a 3,000 B write before any block is written', async () => {
  const sectorKeys = new Map([[33, new Uint8Array([1, 2, 3, 4, 5, 6])]]);
  const { transport, device } = await tap4k({ allow4k: on, sectorKeys });
  await assert.rejects(() => transport.writeChunk(chunkBytes(3000)), CardAuthError);
  assert.equal(device.writeCount, 0);
});

test('writes over 752 B probe each touched sector once, in order, before the first write', async () => {
  const { transport, device } = await tap4k({ allow4k: on });
  const events: string[] = [];
  const read = device.readBlock.bind(device);
  const write = device.writeBlock.bind(device);
  device.readBlock = async (b, k) => { events.push(`r${b}`); return read(b, k); };
  device.writeBlock = async (b, k, d) => { events.push(`w${b}`); return write(b, k, d); };
  await transport.writeChunk(chunkBytes(800)); // 832 B = 52 blocks: 2 in sector 0, 3 per sector after, so sectors 0..17
  const firstWrite = events.findIndex((e) => e.startsWith('w'));
  const probes = events.slice(0, firstWrite);
  const sectors = Array.from({ length: 18 }, (_, i) => i);
  assert.deepEqual(probes, sectors.map((s) => `r${s === 0 ? 1 : s * 4}`));
});

test('4K card, <= 752 B write: same block writes as 1K and no pre-check reads', async () => {
  const bytes = chunkBytes(720); // exactly 752
  const { transport, device } = await tap4k({ allow4k: on });
  const events: string[] = [];
  const read = device.readBlock.bind(device);
  const write = device.writeBlock.bind(device);
  device.readBlock = async (b, k) => { events.push(`r${b}`); return read(b, k); };
  device.writeBlock = async (b, k, d) => { events.push(`w${b}`); return write(b, k, d); };
  await transport.writeChunk(bytes);
  const expectedWrites = chunkToBlocks(bytes).map((x) => `w${x.block}`);
  assert.deepEqual(events.slice(0, expectedWrites.length), expectedWrites); // writes first, no reads before
  assert.equal(events.filter((e) => e.startsWith('w')).length, 47);
});

test('a short read in the middle of a 4K chunk is a CardReadError, not data', async () => {
  const { transport, device } = await tap4k({ allow4k: on });
  await transport.writeChunk(chunkBytes(3000));
  device.truncateNextRead(4);
  await assert.rejects(() => transport.readChunk(), CardReadError);
});
