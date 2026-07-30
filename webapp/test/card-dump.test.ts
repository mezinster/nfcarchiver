import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dumpCard, type DumpMeta, type DumpUnit } from '../src/inspect/card-dump.js';
import { NtagType, ntagTotalPages } from '../src/nfc/type2.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { FakeChameleon } from './fake-chameleon.js';

const CLASSIC_UID = new Uint8Array([0xb9, 0x16, 0x27, 0x51]);
const NTAG_UID = new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]);

/** Collect every unit the dump emits, plus the progress pairs and meta. */
function collector() {
  const units: DumpUnit[] = [];
  const progress: Array<[number, number]> = [];
  const order: string[] = [];
  const cb = {
    onMeta: (m: DumpMeta) => { order.push(`meta:${m.medium}`); },
    onUnit: (u: DumpUnit, done: number, total: number) => {
      units.push(u); progress.push([done, total]); order.push('unit');
    },
  };
  return { units, progress, order, cb };
}

test('Mifare Classic: dumps all 64 blocks, labelling manufacturer and trailers', async () => {
  const device = new FakeChameleon();
  device.place(CLASSIC_UID);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.meta.medium, 'mifare-classic-1k');
  assert.equal(res.meta.sak, 0x08);
  assert.equal(res.units.length, 64);
  assert.equal(c.units.length, 64, 'every unit must also be reported live');
  assert.deepEqual(c.progress[0], [1, 64]);
  assert.deepEqual(c.progress[63], [64, 64]);

  assert.equal(res.units[0]!.kind, 'manufacturer');
  assert.equal(res.units[1]!.kind, 'data');
  assert.equal(res.units[3]!.kind, 'trailer');
  assert.equal(res.units[63]!.kind, 'trailer');
  assert.equal(res.units[4]!.sector, 1);
  assert.ok(res.units.every((u) => u.bytes?.length === 16), 'a factory-keyed card reads clean');
  assert.equal(res.aborted, false);
  assert.equal(res.cardLost, false);
  // onMeta must land before any unit: the dialog shows identity in ~1 s rather
  // than after 64 BLE round trips.
  assert.equal(c.order[0], 'meta:mifare-classic-1k');
  assert.equal(c.order[1], 'unit');
});

test('Mifare Classic: non-factory keys mark units auth-failed without aborting', async () => {
  const device = new FakeChameleon();
  device.defineCard(CLASSIC_UID, { keyA: new Uint8Array([1, 2, 3, 4, 5, 6]) });
  device.place(CLASSIC_UID);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.units.length, 64, 'the dump must run to completion');
  assert.ok(res.units.every((u) => u.failure === 'auth-failed'));
  assert.ok(res.units.every((u) => u.bytes === undefined));
  assert.equal(res.cardLost, false, 'a wrong key is not a lost card');
});

test('Mifare Classic: a non-auth read failure stops early and marks the rest not-read', async () => {
  const fake = new FakeChameleon();
  fake.place(CLASSIC_UID);
  let reads = 0;
  // FakeChameleon signals an empty field as CardAuthError, which is a fake
  // artifact; real hardware surfaces a card leaving the field as something
  // else. Wrap it so the non-auth branch is what gets exercised.
  const device: ChameleonDevice = {
    ...fake,
    isConnected: () => fake.isConnected(),
    connect: () => fake.connect(),
    disconnect: () => fake.disconnect(),
    scanTag: () => fake.scanTag(),
    transceive14a: (d, o) => fake.transceive14a(d, o),
    writeBlock: (b, k, d) => fake.writeBlock(b, k, d),
    readBlock: async (b, k) => {
      reads++;
      if (reads > 10) throw new Error('BLE link lost');
      return fake.readBlock(b, k);
    },
  };
  const c = collector();
  const res = await dumpCard(device, c.cb);

  assert.equal(res.units.length, 64, 'the result must still describe the whole card');
  assert.equal(res.cardLost, true);
  assert.ok(res.units.slice(0, 10).every((u) => u.bytes?.length === 16));
  assert.ok(res.units.slice(10).every((u) => u.failure === 'not-read'));
  assert.equal(reads, 11, 'must stop reading, not grind through 53 more failing round trips');
});

test('NTAG213: dumps every page group, truncating the final short group', async () => {
  const device = new FakeChameleon();
  device.placeNtag(NTAG_UID, NtagType.NTAG213);
  const c = collector();
  const res = await dumpCard(device, c.cb);

  const pages = ntagTotalPages(NtagType.NTAG213); // 45
  const groups = Math.ceil(pages / 4);            // 12
  assert.equal(res.meta.medium, NtagType.NTAG213);
  assert.equal(res.units.length, groups);
  assert.equal(res.units[0]!.kind, 'cc', 'group 0 holds UID, lock bytes and the Capability Container');
  assert.equal(res.units[0]!.bytes!.length, 16);
  // 45 pages is not a multiple of 4: the last group is a single page.
  assert.equal(res.units[groups - 1]!.index, 44);
  assert.equal(res.units[groups - 1]!.bytes!.length, 4, 'a short FINAL group is end-of-memory, not a failure');
  assert.equal(res.units[groups - 1]!.failure, undefined);
  // The CC the fake bakes in at page 3.
  assert.deepEqual(Array.from(res.units[0]!.bytes!.subarray(12, 16)), [0xe1, 0x10, 0x12, 0x00]);
});

test('NTAG213: a full 16-byte response on the final group is truncated to the real page, not the wrapped filler', async () => {
  const fake = new FakeChameleon();
  fake.placeNtag(NTAG_UID, NtagType.NTAG213);
  const REAL_PAGE_44 = new Uint8Array([0x11, 0x22, 0x33, 0x44]);
  const WRAPPED_FILLER = new Uint8Array(12).fill(0xaa); // stands in for wrapped pages 0-2
  const device: ChameleonDevice = {
    ...fake,
    isConnected: () => fake.isConnected(),
    connect: () => fake.connect(),
    disconnect: () => fake.disconnect(),
    scanTag: () => fake.scanTag(),
    writeBlock: (b, k, d) => fake.writeBlock(b, k, d),
    readBlock: (b, k) => fake.readBlock(b, k),
    transceive14a: async (d, o) => {
      if (d[0] === 0x30 && d[1] === 44) {
        // Real hardware: READ always returns 4 pages, wrapping to page 0 at
        // the end of memory. Page 44 is the sole real page in this group.
        const resp = new Uint8Array(16);
        resp.set(REAL_PAGE_44, 0);
        resp.set(WRAPPED_FILLER, 4);
        return resp;
      }
      return fake.transceive14a(d, o);
    },
  };
  const c = collector();
  const res = await dumpCard(device, c.cb);

  const pages = ntagTotalPages(NtagType.NTAG213); // 45
  const groups = Math.ceil(pages / 4);            // 12
  const finalUnit = res.units[groups - 1]!;
  assert.equal(finalUnit.index, 44);
  assert.equal(finalUnit.failure, undefined);
  assert.equal(finalUnit.bytes!.length, 4, 'must be truncated to the one real page, not the full wrap-around response');
  assert.deepEqual(Array.from(finalUnit.bytes!), Array.from(REAL_PAGE_44));
});

test('NTAG213: a short response on a NON-final group is a failure, not end-of-memory', async () => {
  const fake = new FakeChameleon();
  fake.placeNtag(NTAG_UID, NtagType.NTAG213);
  const device: ChameleonDevice = {
    ...fake,
    isConnected: () => fake.isConnected(),
    connect: () => fake.connect(),
    disconnect: () => fake.disconnect(),
    scanTag: () => fake.scanTag(),
    writeBlock: (b, k, d) => fake.writeBlock(b, k, d),
    readBlock: (b, k) => fake.readBlock(b, k),
    transceive14a: async (d, o) => {
      if (d[0] === 0x30 && d[1] === 16) {
        return new Uint8Array(8); // marginal coupling: half the requested 16 bytes
      }
      return fake.transceive14a(d, o);
    },
  };
  const c = collector();
  const res = await dumpCard(device, c.cb);

  const pages = ntagTotalPages(NtagType.NTAG213); // 45
  const groups = Math.ceil(pages / 4);            // 12
  assert.equal(res.units.length, groups, 'the dump must still run to completion');
  const shortUnit = res.units.find((u) => u.index === 16)!;
  assert.equal(shortUnit.failure, 'short-read');
  assert.equal(shortUnit.bytes, undefined);
});

test('NTAG: a non-auth read failure stops early and marks the rest not-read', async () => {
  const fake = new FakeChameleon();
  fake.placeNtag(NTAG_UID, NtagType.NTAG213);
  let readCalls = 0;
  const device: ChameleonDevice = {
    ...fake,
    isConnected: () => fake.isConnected(),
    connect: () => fake.connect(),
    disconnect: () => fake.disconnect(),
    scanTag: () => fake.scanTag(),
    writeBlock: (b, k, d) => fake.writeBlock(b, k, d),
    readBlock: (b, k) => fake.readBlock(b, k),
    transceive14a: async (d, o) => {
      if (d[0] === 0x30) {
        readCalls++;
        if (readCalls > 4) throw new Error('BLE link lost');
      }
      return fake.transceive14a(d, o);
    },
  };
  const c = collector();
  const res = await dumpCard(device, c.cb);

  const pages = ntagTotalPages(NtagType.NTAG213); // 45
  const groups = Math.ceil(pages / 4);            // 12
  assert.equal(res.units.length, groups, 'the result must still describe the whole card');
  assert.equal(res.cardLost, true);
  assert.ok(res.units.slice(0, 4).every((u) => u.bytes !== undefined));
  assert.ok(res.units.slice(4).every((u) => u.failure === 'not-read'));
  assert.equal(readCalls, 5, 'must stop reading, not grind through the remaining 7 failing round trips');
});

test('abort stops the dump and reports it', async () => {
  const device = new FakeChameleon();
  device.place(CLASSIC_UID);
  const ac = new AbortController();
  const units: DumpUnit[] = [];
  const res = await dumpCard(device, {
    onUnit: (u) => { units.push(u); if (units.length === 5) ac.abort(); },
  }, ac.signal);

  assert.equal(res.aborted, true);
  assert.ok(units.length >= 5 && units.length < 64, `expected an early stop, got ${units.length}`);
});

test('an unsupported SAK is rejected before any read', async () => {
  const device = new FakeChameleon();
  device.defineCard(CLASSIC_UID, { sak: 0x20 });
  device.place(CLASSIC_UID);
  await assert.rejects(() => dumpCard(device, { onUnit: () => {} }), UnsupportedTagError);
});
