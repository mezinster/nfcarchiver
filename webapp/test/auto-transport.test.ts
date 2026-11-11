import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType } from '../src/nfc/type2.js';
import { CARD_CAPACITY_BYTES } from '../src/mifare/card-layout.js';
import { log } from '../src/log/logger.js';

test('a Mifare Classic (SAK 0x08) routes to the Classic transport', async () => {
  const device = new FakeChameleon();
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.place(new Uint8Array([1, 2, 3, 4])); // FakeChameleon default sak 0x08
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, CARD_CAPACITY_BYTES); // 752 => Classic delegate
});

test('an NTAG (SAK 0x00) routes to the NTAG transport', async () => {
  const device = new FakeChameleon();
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  device.placeNtag(new Uint8Array([0x04, 1, 2, 3, 4, 5, 6]), NtagType.NTAG216);
  const tag = await t.awaitTag();
  assert.equal(tag.capacityBytes, 888); // NTAG216 => NTAG delegate
});

test('an unknown SAK throws UnsupportedTagError', async () => {
  const device = new FakeChameleon();
  device.defineCard(new Uint8Array([7, 7, 7, 7]), { sak: 0x20 });
  device.place(new Uint8Array([7, 7, 7, 7]));
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 200 });
  await t.connect();
  await assert.rejects(() => t.awaitTag(), UnsupportedTagError);
});

for (const sak of [0x18, 0x38, 0x98]) {
  test(`SAK 0x${sak.toString(16)} routes to the Classic transport as a 4K card`, async () => {
    const device = new FakeChameleon();
    device.defineCard(new Uint8Array([4, 4, 4, 4]), { sak });
    device.place(new Uint8Array([4, 4, 4, 4]));
    const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500, allow4k: () => true });
    await t.connect();
    const tag = await t.awaitTag();
    assert.equal(tag.capacityBytes, 3440);
    assert.equal(tag.maxChunkPayload, 3408);
  });
}

test('a 2K card (SAK 0x19) is unsupported', async () => {
  const device = new FakeChameleon();
  device.defineCard(new Uint8Array([2, 2, 2, 2]), { sak: 0x19 });
  device.place(new Uint8Array([2, 2, 2, 2]));
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 200, allow4k: () => true });
  await t.connect();
  await assert.rejects(() => t.awaitTag(), UnsupportedTagError);
});

test('every tap logs its SAK at info level', async () => {
  const device = new FakeChameleon();
  device.defineCard(new Uint8Array([3, 3, 3, 3]), { sak: 0x38 });
  device.place(new Uint8Array([3, 3, 3, 3]));
  const t = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await t.connect();
  await t.awaitTag();
  const entry = log.snapshot().filter((e) => e.level === 'info' && e.msg.includes('SAK')).pop();
  assert.ok(entry, 'expected an info entry mentioning SAK');
  assert.match(entry!.msg, /0x38/);
});
