import { test } from 'node:test';
import assert from 'node:assert/strict';
import { uidFromSerialNumber } from '../src/transport/ndef-io.js';

test('uidFromSerialNumber parses the colon-separated hex Chrome reports', () => {
  assert.deepEqual(
    Array.from(uidFromSerialNumber('04:7b:cd:a4:82:26:81')),
    [0x04, 0x7b, 0xcd, 0xa4, 0x82, 0x26, 0x81],
  );
});

test('uidFromSerialNumber tolerates upper case and an empty serial', () => {
  assert.deepEqual(Array.from(uidFromSerialNumber('AB:CD')), [0xab, 0xcd]);
  assert.deepEqual(Array.from(uidFromSerialNumber('')), []);
});

test('uidFromSerialNumber throws on trailing colon', () => {
  assert.throws(() => uidFromSerialNumber('04:7b:'), Error);
});

test('uidFromSerialNumber throws on non-hex segment', () => {
  assert.throws(() => uidFromSerialNumber('04:zz:81'), Error);
});

test('uidFromSerialNumber throws on over-long segment', () => {
  assert.throws(() => uidFromSerialNumber('04:7bc'), Error);
});

import { WebNfcTransport } from '../src/transport/web-nfc-transport.js';
import { FakeNdefIO } from './fake-ndef-io.js';
import { NtagType, webNfcChunkPayload, ntagFactoryNdefCapacity } from '../src/nfc/type2.js';
import { runTransportContract } from './transport-contract.js';
import { encodeNdefMime } from '../src/nfc/ndef.js';
import { encodeChunk, NfarFormatError, type Chunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { TagTimeoutError } from '../src/transport/transport.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';

function nfarRecords(payloadLen: number) {
  const payload = new Uint8Array(payloadLen).map((_, i) => (i + 1) % 256);
  const c: Chunk = {
    archiveId: new Uint8Array(16).fill(9),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  };
  const bytes = encodeChunk(c);
  return {
    bytes,
    records: [{
      recordType: 'mime',
      mediaType: 'application/vnd.nfcarchiver.chunk',
      data: bytes,
    }],
  };
}

test('awaitTag reports the UID and the selected type capacity', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  const tag = await t.awaitTag();
  assert.deepEqual(Array.from(tag.uid), [4, 1, 2, 3]);
  assert.equal(tag.maxChunkPayload, webNfcChunkPayload(NtagType.NTAG215));
  assert.equal(tag.maxChunkPayload, 420);
});

test('peekIsNfar uses the cached reading — no second tap', async () => {
  const io = new FakeNdefIO();
  const { records } = nfarRecords(50);
  io.tap('04:01:02:03', records);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);
  // A second tap was never queued; if peek had consumed one this would throw.
  assert.deepEqual(await t.readChunk(), records[0]!.data);
});

test('a blank tag peeks false rather than throwing', async () => {
  const io = new FakeNdefIO();
  io.tap('04:09:09:09', []);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), false);
});

test('a foreign NDEF record peeks false', async () => {
  const io = new FakeNdefIO();
  io.tap('04:09:09:09', [{ recordType: 'text', data: new Uint8Array([1, 2, 3]) }]);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), false);
});

test('writeChunk emits one MIME record with the NFAR media type', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  const { bytes } = nfarRecords(50);
  await t.writeChunk(bytes);
  assert.equal(io.writes.length, 1);
  assert.equal(io.writes[0]!.length, 1);
  assert.equal(io.writes[0]![0]!.mediaType, 'application/vnd.nfcarchiver.chunk');
  assert.deepEqual(io.writes[0]![0]!.data, bytes);
});

test('awaitTag rejects TagTimeoutError when no tag is presented', async () => {
  const t = new WebNfcTransport(new FakeNdefIO(), NtagType.NTAG215);
  await t.connect();
  await assert.rejects(() => t.awaitTag(), TagTimeoutError);
});

test('writeChunk accepts a chunk exactly at the payload boundary and rejects one byte more', async () => {
  const max = webNfcChunkPayload(NtagType.NTAG215);

  const io1 = new FakeNdefIO();
  io1.tap('04:01:02:03');
  const t1 = new WebNfcTransport(io1, NtagType.NTAG215);
  await t1.connect();
  await t1.awaitTag();
  const { bytes: atMax } = nfarRecords(max);
  await t1.writeChunk(atMax); // must not throw — exactly fills the CC-declared NDEF area

  const io2 = new FakeNdefIO();
  io2.tap('04:01:02:03');
  const t2 = new WebNfcTransport(io2, NtagType.NTAG215);
  await t2.connect();
  await t2.awaitTag();
  const { bytes: overMax } = nfarRecords(max + 1);
  await assert.rejects(() => t2.writeChunk(overMax), CardCapacityError);
});

test('a failed awaitTag() clears the stale cache from the previous tag', async () => {
  const io = new FakeNdefIO();
  const { records } = nfarRecords(50);
  io.tap('04:01:02:03', records);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true);

  // Nothing queued: this awaitTag() rejects. Card A's reading must not linger.
  await assert.rejects(() => t.awaitTag(), TagTimeoutError);
  assert.equal(await t.peekIsNfar(), false);
  await assert.rejects(() => t.readChunk(), NfarFormatError);
});

test('writeChunk invalidates the cache — a stale peek/read cannot serve pre-write content', async () => {
  const io = new FakeNdefIO();
  // The tag already holds NFAR content before the write, so a cache that is
  // merely left untouched (rather than invalidated) would misreport success:
  // peekIsNfar() would still see the OLD record and answer true.
  const { records: oldRecords } = nfarRecords(50);
  io.tap('04:01:02:03', oldRecords);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await t.awaitTag();
  assert.equal(await t.peekIsNfar(), true); // sanity: old content visible pre-write

  const { bytes: newBytes } = nfarRecords(60);
  await t.writeChunk(newBytes);

  // No re-tap yet: the cache must not silently serve the pre-write reading as
  // if it reflected the new write.
  assert.equal(await t.peekIsNfar(), false);
  await assert.rejects(() => t.readChunk(), NfarFormatError);
});

test('readChunk before any awaitTag() throws NfarFormatError rather than crashing', async () => {
  const t = new WebNfcTransport(new FakeNdefIO(), NtagType.NTAG215);
  await t.connect();
  assert.equal(await t.peekIsNfar(), false);
  await assert.rejects(() => t.readChunk(), NfarFormatError);
});

runTransportContract('WebNfcTransport+FakeNdefIO', () => {
  const io = new FakeNdefIO();
  const transport = new WebNfcTransport(io, NtagType.NTAG215);
  return {
    transport,
    tap: (uid: Uint8Array) => {
      io.tap(Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join(':'));
    },
  };
}, {
  capacityBytes: ntagFactoryNdefCapacity(NtagType.NTAG215),
  maxChunkPayload: webNfcChunkPayload(NtagType.NTAG215),
});
