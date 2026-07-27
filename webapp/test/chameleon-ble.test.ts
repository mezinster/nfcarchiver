import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChameleonBleTransport, NotImplementedError, type ChameleonUltraLike } from '../src/transport/chameleon-ble.js';

function fakeDevice(): ChameleonUltraLike & { connected: boolean } {
  return {
    connected: false,
    async connect() { this.connected = true; },
    async disconnect() { this.connected = false; },
    isConnected() { return this.connected; },
  };
}

test('delegates connect/disconnect to the SDK device', async () => {
  const device = fakeDevice();
  const t = new ChameleonBleTransport(device);
  await t.connect();
  assert.ok(device.connected);
  await t.disconnect();
  assert.ok(!device.connected);
});

test('reports Mifare Classic 1K usable capacity', async () => {
  const t = new ChameleonBleTransport(fakeDevice());
  assert.equal(await t.detectCapacity(), 752);
});

test('block-mapping operations are explicit stubs', async () => {
  const t = new ChameleonBleTransport(fakeDevice());
  await assert.rejects(() => t.writeChunk(new Uint8Array(16)), NotImplementedError);
  await assert.rejects(() => t.readChunk(), NotImplementedError);
});
