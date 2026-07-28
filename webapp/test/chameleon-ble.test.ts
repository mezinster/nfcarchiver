import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';
import { NfarFormatError } from '../src/chunk.js';
import { FakeChameleon } from './fake-chameleon.js';
import { runTransportContract } from './transport-contract.js';
import { encodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { USABLE_BLOCK_INDEXES, CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';

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
});

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
