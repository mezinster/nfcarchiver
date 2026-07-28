import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { UnsupportedTagError } from '../src/transport/transport.js';
import { FakeChameleon } from './fake-chameleon.js';
import { NtagType } from '../src/nfc/type2.js';
import { CARD_CAPACITY_BYTES } from '../src/mifare/card-layout.js';

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
