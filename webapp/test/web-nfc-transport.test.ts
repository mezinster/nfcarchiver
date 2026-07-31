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
