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
import { TagTimeoutError, UnidentifiedTagError } from '../src/transport/transport.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { ArchiveController, RestoreController } from '../app/controller.js';

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
  // A real card WAS presented and read — it simply holds no NFAR data. That is
  // the one case NfarFormatError describes.
  await assert.rejects(() => t.readChunk(), NfarFormatError);
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
  const io = new FakeNdefIO();
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  // The tightened fake only fails fast when timeoutMs is set — with none, it
  // waits for a tap that will never come (real Web NFC has no built-in
  // timeout either). A bare awaitTag() would hang the suite, so this asserts
  // through an explicit timeout, same as the transport contract does.
  await assert.rejects(() => t.awaitTag({ timeoutMs: 20 }), TagTimeoutError);
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
  // timeoutMs is required for the tightened fake to fail fast rather than wait
  // forever for a tap that never comes.
  await assert.rejects(() => t.awaitTag({ timeoutMs: 20 }), TagTimeoutError);
  assert.equal(await t.peekIsNfar(), false);
  await assert.rejects(() => t.readChunk(), UnidentifiedTagError);
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
  await assert.rejects(() => t.readChunk(), UnidentifiedTagError);
});

test('readChunk with no tag present reports "no tag", not "bad tag"', async () => {
  const t = new WebNfcTransport(new FakeNdefIO(), NtagType.NTAG215);
  await t.connect();
  assert.equal(await t.peekIsNfar(), false);
  // NfarFormatError would claim we looked at a card and it held no NFAR data.
  // No card was ever presented — a different fact, and a different error.
  await assert.rejects(() => t.readChunk(), UnidentifiedTagError);
});

test('awaitTag rejects a blank serial instead of minting a colliding identity', async () => {
  const io = new FakeNdefIO();
  io.tap('', nfarRecords(50).records);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  await assert.rejects(() => t.awaitTag(), UnidentifiedTagError);
  // The unusable reading must not be cached either: peek/read on a card whose
  // identity we could not establish would speak for an unknown card.
  assert.equal(await t.peekIsNfar(), false);
  await assert.rejects(() => t.readChunk(), UnidentifiedTagError);
});

test('blank-serial cards cannot collide into one archive identity', async () => {
  // Every blank serial used to map to uid key '' — card 2 looked "already
  // written" and writeNextCard returned {done:false} with no error and no
  // progress, so the archive could never finish.
  const io = new FakeNdefIO();
  io.tap('');
  io.tap('');
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({
    data: crypto.getRandomValues(new Uint8Array(1200)),
    fileName: 'blob.bin', compress: false, payloadSize: 420,
  });
  assert.ok(total >= 2, `expected a multi-card archive, got ${total}`);
  await assert.rejects(() => ctrl.writeNextCard(), UnidentifiedTagError);
  await assert.rejects(() => ctrl.writeNextCard(), UnidentifiedTagError);
  assert.equal(io.writes.length, 0, 'nothing may be written under an identity we could not establish');
});

test('a blank-serial card fails a restore scan loudly instead of being dropped', async () => {
  const io = new FakeNdefIO();
  io.tap('', nfarRecords(50).records);
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  const ctrl = new RestoreController(t);
  await assert.rejects(() => ctrl.scanNextCard(), UnidentifiedTagError);
  assert.deepEqual(ctrl.detectedArchives(), [], 'no archive may be attributed to an unidentified card');
});

runTransportContract('WebNfcTransport+FakeNdefIO', () => {
  const io = new FakeNdefIO();
  // connect() (called by runTransportContract itself) now arms the scan, so
  // the factory need only build the transport.
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

test('a multi-card scan arms the reader exactly once', async () => {
  const io = new FakeNdefIO();
  const t = new WebNfcTransport(io, NtagType.NTAG215);
  await t.connect();
  for (let i = 1; i <= 3; i++) {
    io.tap(`04:0${i}:02:03`);
    const tag = await t.awaitTag();
    assert.equal(tag.uid[1], i);
  }
  assert.equal(io.scanArmCount, 1, 'each card must reuse the one scan');
});

test('reading before the scan is started is a programming error', async () => {
  const io = new FakeNdefIO();
  io.tap('04:01:02:03');
  await assert.rejects(() => io.awaitReading(), /not started/i);
});

test('starting twice is rejected, as the real API does', async () => {
  const io = new FakeNdefIO();
  await io.start();
  await assert.rejects(() => io.start(), /already/i);
});

test('connect arms the scan, and a refusal surfaces from connect', async () => {
  const ok = new FakeNdefIO();
  await new WebNfcTransport(ok, NtagType.NTAG215).connect();
  assert.equal(ok.scanArmCount, 1);

  const bad = new FakeNdefIO();
  bad.failStart = new Error('NFC permission denied');
  await assert.rejects(
    () => new WebNfcTransport(bad, NtagType.NTAG215).connect(),
    /permission denied/,
  );
});
