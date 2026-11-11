import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifySak, cardSizeFor } from '../src/mifare/sak.js';

test('classifySak', () => {
  assert.equal(classifySak(0x08), 'classic1k');
  for (const s of [0x18, 0x38, 0x98]) assert.equal(classifySak(s), 'classic4k');
  assert.equal(classifySak(0x00), 'ntag');
  for (const s of [0x19, 0x09, 0x28, 0x20]) assert.equal(classifySak(s), 'unsupported', `0x${s.toString(16)}`);
});

test('cardSizeFor', () => {
  assert.equal(cardSizeFor('classic1k'), '1k');
  assert.equal(cardSizeFor('classic4k'), '4k');
  assert.equal(cardSizeFor('ntag'), null);
  assert.equal(cardSizeFor('unsupported'), null);
});
