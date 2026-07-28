import { test } from 'node:test';
import assert from 'node:assert/strict';
import { estimateCardCount } from '../app/estimate.js';

test('empty input is 0 cards', async () => {
  assert.equal(await estimateCardCount(new Uint8Array(0), 'text_note.txt', { compress: false, encrypted: false, payloadSize: 720 }), 0);
});

test('uncompressed count uses wrapped size over 720', async () => {
  // fileName 'f' = 1 byte -> wrapped overhead = 2 + 1 = 3.
  const at720 = new Uint8Array(717); // wrapped = 720 -> 1 card
  assert.equal(await estimateCardCount(at720, 'f', { compress: false, encrypted: false, payloadSize: 720 }), 1);
  const over = new Uint8Array(718); // wrapped = 721 -> 2 cards
  assert.equal(await estimateCardCount(over, 'f', { compress: false, encrypted: false, payloadSize: 720 }), 2);
});

test('encryption adds the 44-byte overhead', async () => {
  const data = new Uint8Array(700); // wrapped (name 'f') = 703; +44 = 747 -> 2 cards
  assert.equal(await estimateCardCount(data, 'f', { compress: false, encrypted: true, payloadSize: 720 }), 2);
  assert.equal(await estimateCardCount(data, 'f', { compress: false, encrypted: false, payloadSize: 720 }), 1);
});

test('compression shrinks a repetitive payload to a single card', async () => {
  const data = new Uint8Array(4000).fill(0x61); // highly compressible
  assert.equal(await estimateCardCount(data, 'text_note.txt', { compress: false, encrypted: false, payloadSize: 720 }), 6);
  assert.equal(await estimateCardCount(data, 'text_note.txt', { compress: true, encrypted: false, payloadSize: 720 }), 1);
});
