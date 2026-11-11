import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  isDevUnlocked, unlockDev, isMifare4kEnabled, setMifare4kEnabled, onMifare4kChange,
} from '../app/dev-flags.js';

const g = globalThis as { localStorage?: unknown };
let saved: unknown;
beforeEach(() => { saved = g.localStorage; });
afterEach(() => { g.localStorage = saved; });

function mapStorage(): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => { m.set(k, v); },
    removeItem: (k: string) => { m.delete(k); },
  } as unknown as Storage;
}

const throwingStorage = (): Storage => {
  const boom = (): never => { throw new Error('blocked'); };
  return { getItem: boom, setItem: boom, removeItem: boom } as unknown as Storage;
};

test('flags default to false', () => {
  g.localStorage = mapStorage();
  assert.equal(isDevUnlocked(), false);
  assert.equal(isMifare4kEnabled(), false);
});

test('unlock and 4K switch round-trip', () => {
  g.localStorage = mapStorage();
  unlockDev();
  assert.equal(isDevUnlocked(), true);
  setMifare4kEnabled(true);
  assert.equal(isMifare4kEnabled(), true);
  setMifare4kEnabled(false);
  assert.equal(isMifare4kEnabled(), false);
});

test('throwing storage reads as false and never throws', () => {
  g.localStorage = throwingStorage();
  assert.equal(isDevUnlocked(), false);
  assert.equal(isMifare4kEnabled(), false);
  assert.doesNotThrow(() => { unlockDev(); setMifare4kEnabled(true); });
  assert.equal(isMifare4kEnabled(), false);
});

test('missing localStorage reads as false', () => {
  g.localStorage = undefined;
  assert.equal(isMifare4kEnabled(), false);
});

test('onMifare4kChange fires on set and stops after unsubscribe', () => {
  g.localStorage = mapStorage();
  const seen: boolean[] = [];
  const off = onMifare4kChange((on) => seen.push(on));
  setMifare4kEnabled(true);
  setMifare4kEnabled(false);
  off();
  setMifare4kEnabled(true);
  assert.deepEqual(seen, [true, false]);
});
