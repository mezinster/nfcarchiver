import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NtagTransport } from '../src/transport/ntag-transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType, ntagChunkPayloadSize } from '../src/nfc/type2.js';
import { encodeChunk, decodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import type { ChameleonDevice } from '../src/transport/chameleon-device.js';

const NTAG215_UID = new Uint8Array([0x04, 1, 2, 3, 4, 5, 6]);

/** Minimal ChameleonDevice stub: always presents one NTAG215-ish tag, but
 *  transceive14a's behavior for READ (0x30) is injected per-test. */
function stubDevice(opts: { onRead: (data: Uint8Array) => Promise<Uint8Array>; getVersion?: Uint8Array }): ChameleonDevice {
  let connected = false;
  let scanned = false;
  return {
    isConnected: () => connected,
    connect: async () => { connected = true; },
    disconnect: async () => { connected = false; },
    scanTag: async () => {
      if (scanned) return null; // present the tag exactly once, like a real single tap
      scanned = true;
      return { uid: NTAG215_UID, sak: 0x00 };
    },
    transceive14a: async (data: Uint8Array) => {
      const cmd = data[0];
      if (cmd === 0x60) return opts.getVersion ?? new Uint8Array([0, 4, 4, 2, 1, 0, 0x11, 3]); // NTAG215
      if (cmd === 0x30) return opts.onRead(data);
      throw new Error(`stub does not implement command 0x${cmd?.toString(16)}`);
    },
    readBlock: async () => { throw new Error('not used'); },
    writeBlock: async () => { throw new Error('not used'); },
  };
}

function chunkBytes(payloadLen: number): Uint8Array {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 3) % 256);
  const c: Chunk = { archiveId: new Uint8Array(16).fill(4), totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0 };
  return encodeChunk(c);
}

test('write then read-back an NDEF-wrapped chunk on a simulated NTAG215', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  const uid = new Uint8Array([0x04, 1, 2, 3, 4, 5, 6]);
  device.placeNtag(uid, NtagType.NTAG215);
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, 504);
  assert.equal(await t.peekIsNfar(), false);

  const bytes = chunkBytes(200);
  await t.writeChunk(bytes);
  device.placeNtag(uid, NtagType.NTAG215); // re-present the same card (keeps its pages)
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);
  assert.deepEqual(await t.readChunk(), bytes);
});

test('a chunk larger than the tag capacity is rejected', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.placeNtag(new Uint8Array([0x04, 9, 9, 9, 9, 9, 9]), NtagType.NTAG213);
  await t.awaitTag();
  const tooBig = chunkBytes(ntagChunkPayloadSize(NtagType.NTAG213) + 50);
  await assert.rejects(() => t.writeChunk(tooBig));
});

test('peekIsNfar rethrows a non-format I/O error instead of reporting a blank tag', async () => {
  const ioError = new Error('io glitch');
  const device = stubDevice({ onRead: async () => { throw ioError; } });
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  await t.awaitTag();
  await assert.rejects(() => t.peekIsNfar(), ioError);
});

test('detectType surfaces UnsupportedTagError for an unrecognized GET_VERSION storage byte', async () => {
  const device = stubDevice({
    onRead: async () => { throw new Error('should not read memory before type detection'); },
    getVersion: new Uint8Array([0, 4, 4, 2, 1, 0, 0x99, 3]),
  });
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  await assert.rejects(() => t.awaitTag(), UnsupportedTagError);
});
