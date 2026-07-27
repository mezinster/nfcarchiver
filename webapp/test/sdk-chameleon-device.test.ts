import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SdkChameleonDevice, MF1_KEY_A, type ChameleonUltraSdk } from '../src/transport/sdk-chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';

function fakeSdk(overrides: Partial<ChameleonUltraSdk> = {}): ChameleonUltraSdk & { calls: unknown[] } {
  const calls: unknown[] = [];
  let connected = false;
  return {
    calls,
    isConnected() { return connected; },
    async connect() { connected = true; },
    async disconnect() { connected = false; },
    async cmdHf14aScan() { calls.push(['scan']); return [{ uid: new Uint8Array([1, 2, 3, 4]) }]; },
    async cmdMf1ReadBlock({ block, keyType, key }) { calls.push(['read', block, keyType, [...key]]); return new Uint8Array(16).fill(block); },
    async cmdMf1WriteBlock({ block, keyType, key, data }) { calls.push(['write', block, keyType, [...key], [...data]]); },
    ...overrides,
  } as ChameleonUltraSdk & { calls: unknown[] };
}

test('scanTag returns the first tag UID, or null when none present', async () => {
  const dev = new SdkChameleonDevice(fakeSdk());
  assert.deepEqual(await dev.scanTag(), new Uint8Array([1, 2, 3, 4]));
  const empty = new SdkChameleonDevice(fakeSdk({ async cmdHf14aScan() { return []; } }));
  assert.equal(await empty.scanTag(), null);
});

test('readBlock/writeBlock use key type A and pass the key through', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.readBlock(4, FACTORY_KEY_A);
  await dev.writeBlock(4, FACTORY_KEY_A, new Uint8Array(16).fill(9));
  assert.deepEqual(sdk.calls[0], ['read', 4, MF1_KEY_A, [...FACTORY_KEY_A]]);
  assert.deepEqual(sdk.calls[1], ['write', 4, MF1_KEY_A, [...FACTORY_KEY_A], [...new Uint8Array(16).fill(9)]]);
});

test('connect/disconnect delegate to the SDK', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.connect();
  assert.ok(dev.isConnected());
  await dev.disconnect();
  assert.ok(!dev.isConnected());
});
