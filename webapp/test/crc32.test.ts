import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crc32 } from '../src/crc32.js';

test('crc32 check vector "123456789" -> 0xCBF43926', () => {
  assert.equal(crc32(new TextEncoder().encode('123456789')), 0xcbf43926);
});

test('crc32 of empty input is 0', () => {
  assert.equal(crc32(new Uint8Array(0)), 0);
});

test('crc32 result is unsigned', () => {
  // "a" -> 0xE8B7BE43, which is negative as a signed 32-bit int
  assert.equal(crc32(new TextEncoder().encode('a')), 0xe8b7be43);
});
