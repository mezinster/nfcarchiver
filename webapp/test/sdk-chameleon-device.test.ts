import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'chameleon-ultra.js';
import { SdkChameleonDevice, MF1_KEY_A, type ChameleonUltraSdk } from '../src/transport/sdk-chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError } from '../src/transport/transport.js';

const BRAND = Symbol.for('taichunmin.buffer');

/** True only for the SDK's own branded Buffer, never a plain Uint8Array. */
function isSdkBuffer(v: unknown): boolean {
  return typeof v === 'object' && v !== null && typeof (v as Record<symbol, unknown>)[BRAND] === 'function';
}

function statusError(status: number, message = `status ${status}`): Error {
  return Object.assign(new Error(message), { status });
}

function fakeSdk(overrides: Partial<ChameleonUltraSdk> = {}): ChameleonUltraSdk & { calls: unknown[] } {
  const calls: unknown[] = [];
  let connected = false;
  return {
    calls,
    isConnected() { return connected; },
    async connect() { connected = true; },
    async disconnect() { connected = false; },
    async cmdHf14aScan() {
      calls.push(['scan']);
      return [{ uid: Buffer.from(new Uint8Array([1, 2, 3, 4])), sak: Buffer.from(new Uint8Array([0x08])) }];
    },
    async cmdHf14aRaw() { calls.push(['raw']); return new Uint8Array(); },
    async cmdMf1ReadBlock(opts) {
      assert.ok(isSdkBuffer(opts.key), 'key must be an SDK Buffer, not a plain Uint8Array');
      calls.push(['read', opts.block, opts.keyType, [...opts.key]]);
      return Buffer.from(new Uint8Array(16).fill(opts.block));
    },
    async cmdMf1WriteBlock(opts) {
      assert.ok(isSdkBuffer(opts.key), 'key must be an SDK Buffer, not a plain Uint8Array');
      assert.ok(isSdkBuffer(opts.data), 'data must be an SDK Buffer, not a plain Uint8Array');
      calls.push(['write', opts.block, opts.keyType, [...opts.key], [...opts.data]]);
    },
    ...overrides,
  } as ChameleonUltraSdk & { calls: unknown[] };
}

test('scanTag returns the first tag UID + SAK, or null when none present', async () => {
  const dev = new SdkChameleonDevice(fakeSdk());
  assert.deepEqual(await dev.scanTag(), { uid: new Uint8Array([1, 2, 3, 4]), sak: 0x08 });
  const empty = new SdkChameleonDevice(fakeSdk({ async cmdHf14aScan() { return []; } }));
  assert.equal(await empty.scanTag(), null);
});

test('scanTag returns null for the whole transient acquisition-error family', async () => {
  // not-found(1), stat(2), crc(3), collision(4), bcc(5), parity(7) — all mean
  // "no clean tag this instant", so awaitTag should keep polling, not abort.
  for (const status of [1, 2, 3, 4, 5, 7]) {
    const dev = new SdkChameleonDevice(fakeSdk({
      async cmdHf14aScan() { throw statusError(status, `HF status ${status}`); },
    }));
    assert.equal(await dev.scanTag(), null, `status ${status} should scan as null`);
  }
});

test('scanTag rethrows a non-transient error (auth 6, ATS 8, unknown 99)', async () => {
  for (const status of [6, 8, 99]) {
    const dev = new SdkChameleonDevice(fakeSdk({
      async cmdHf14aScan() { throw statusError(status, `status ${status} broke`); },
    }));
    await assert.rejects(() => dev.scanTag(), new RegExp(`status ${status} broke`));
  }
});

test('readBlock/writeBlock convert key/data to SDK Buffers and pass them through', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.readBlock(4, FACTORY_KEY_A);
  await dev.writeBlock(4, FACTORY_KEY_A, new Uint8Array(16).fill(9));
  assert.deepEqual(sdk.calls[0], ['read', 4, MF1_KEY_A, [...FACTORY_KEY_A]]);
  assert.deepEqual(sdk.calls[1], ['write', 4, MF1_KEY_A, [...FACTORY_KEY_A], [...new Uint8Array(16).fill(9)]]);
});

test('readBlock/writeBlock surface an auth-failure status (6) as CardAuthError', async () => {
  const readDev = new SdkChameleonDevice(fakeSdk({
    async cmdMf1ReadBlock() { throw statusError(6, 'auth failed'); },
  }));
  await assert.rejects(() => readDev.readBlock(4, FACTORY_KEY_A), CardAuthError);

  const writeDev = new SdkChameleonDevice(fakeSdk({
    async cmdMf1WriteBlock() { throw statusError(6, 'auth failed'); },
  }));
  await assert.rejects(() => writeDev.writeBlock(4, FACTORY_KEY_A, new Uint8Array(16)), CardAuthError);
});

test('readBlock/writeBlock rethrow non-auth SDK errors', async () => {
  const readDev = new SdkChameleonDevice(fakeSdk({
    async cmdMf1ReadBlock() { throw statusError(2, 'not supported'); },
  }));
  await assert.rejects(() => readDev.readBlock(4, FACTORY_KEY_A), /not supported/);
});

test('connect/disconnect delegate to the SDK', async () => {
  const sdk = fakeSdk();
  const dev = new SdkChameleonDevice(sdk);
  await dev.connect();
  assert.ok(dev.isConnected());
  await dev.disconnect();
  assert.ok(!dev.isConnected());
});
