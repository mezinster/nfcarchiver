import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NtagTransport } from '../src/transport/ntag-transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType, ntagChunkPayloadSize, chunkPayloadForCapacity } from '../src/nfc/type2.js';
import { wrapType2Tlv } from '../src/nfc/type2.js';
import { encodeNdefMime } from '../src/nfc/ndef.js';
import { encodeChunk, decodeChunk, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { runTransportContract } from './transport-contract.js';

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
      if (cmd === 0x30) {
        // awaitTag reads the Capability Container at page 3; return a valid NTAG215
        // CC so tag presentation succeeds and per-test onRead governs page >= 4.
        if (data[1] === 3) { const cc = new Uint8Array(16); cc.set([0xe1, 0x10, 0x3e, 0x00]); return cc; }
        return opts.onRead(data);
      }
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
  assert.equal(tag.capacityBytes, 504); // raw user memory (informational)
  // maxChunkPayload comes from the CC-declared NDEF area (496 B), NOT raw memory
  // (504 B) — smaller, so the whole TLV stays within what Android reads back.
  assert.equal(tag.maxChunkPayload, chunkPayloadForCapacity(496));
  assert.ok(tag.maxChunkPayload < ntagChunkPayloadSize(NtagType.NTAG215), 'CC area is below raw user memory');
  assert.equal(await t.peekIsNfar(), false);

  const bytes = chunkBytes(200);
  await t.writeChunk(bytes);
  device.placeNtag(uid, NtagType.NTAG215); // re-present the same card (keeps its pages)
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);
  assert.deepEqual(await t.readChunk(), bytes);
});

test('a full-size chunk stays within the CC-declared NDEF area so Android can read it back', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  const uid = new Uint8Array([0x04, 5, 5, 5, 5, 5, 5]);
  device.placeNtag(uid, NtagType.NTAG215);
  const tag = await t.awaitTag();

  // The whole NDEF+TLV of a maximum chunk must fit the 496 B the NTAG215 CC
  // declares. The pre-fix bug sized to 504 B raw memory, overflowing by 8 B, so
  // Android's CC-bounded read truncated every full chunk and CRC failed.
  const full = chunkBytes(tag.maxChunkPayload);
  const wrapped = wrapType2Tlv(encodeNdefMime(full)).length;
  assert.ok(wrapped <= 496, `full chunk wraps to ${wrapped} B; must fit the 496 B CC area`);

  // The transport rejects a chunk sized to raw user memory (the old maximum)
  // rather than silently writing a tag Android cannot read.
  const rawSized = chunkBytes(ntagChunkPayloadSize(NtagType.NTAG215));
  await assert.rejects(() => t.writeChunk(rawSized), /NDEF area/);

  // A CC-sized chunk writes and reads back intact.
  await t.writeChunk(full);
  device.placeNtag(uid, NtagType.NTAG215);
  await t.awaitTag();
  assert.deepEqual(await t.readChunk(), full);
});

test('an interrupted write leaves an empty NDEF TLV, never a stale length over new bytes', async () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  const uid = new Uint8Array([0x04, 7, 7, 7, 7, 7, 7]);
  device.placeNtag(uid, NtagType.NTAG215);
  await t.awaitTag();

  // A card that already holds a complete, valid chunk.
  await t.writeChunk(chunkBytes(200));
  device.placeNtag(uid, NtagType.NTAG215);
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);

  // Now the card leaves the field a few pages into overwriting it.
  device.placeNtag(uid, NtagType.NTAG215);
  await t.awaitTag();
  device.failWriteAfter(3);
  await assert.rejects(() => t.writeChunk(chunkBytes(200)));

  // The TLV header must declare a ZERO-length NDEF message. Writing the real
  // header first would leave a card announcing a full-length record over bytes
  // that were never finished — which is what Android rejects outright as "not
  // NDEF", with no way for the user to tell a half-written card from a dead one.
  const header = device.pageOf(uid, 4);
  assert.equal(header[0], 0x03, 'NDEF TLV tag must survive');
  assert.equal(header[1], 0x00, 'TLV length must read as empty, not the new chunk length');
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

// An NTAG215's CC declares a 496 B NDEF area, so its usable chunk payload is
// chunkPayloadForCapacity(496) = 420 — smaller than raw user memory (504).
runTransportContract('NtagTransport+FakeChameleon', () => {
  const device = new FakeChameleon();
  const t = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  return {
    transport: t,
    tap: (uid: Uint8Array) => { device.placeNtag(uid, NtagType.NTAG215); },
  };
}, { capacityBytes: 504, maxChunkPayload: chunkPayloadForCapacity(496) });
