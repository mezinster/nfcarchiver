import { test } from 'node:test';
import assert from 'node:assert/strict';
import { filenameWrapperBytes, photoByteBudget, tagsNeeded } from '../src/photo/budget.js';
import { wrapWithFilename } from '../src/filename.js';
import { ENCRYPTION_OVERHEAD } from '../src/crypto.js';
import { estimateCardCount } from '../app/estimate.js';
import { NtagType, ntagChunkPayloadSize, webNfcChunkPayload } from '../src/nfc/type2.js';
import { payloadSize as mifarePayloadSize } from '../src/mifare/card-layout.js';

// The payload per card of every medium the app can write, from the code that
// sizes real archives, not copied numbers.
const payloads = [
  ...[NtagType.NTAG213, NtagType.NTAG215, NtagType.NTAG216].flatMap((t) => [
    ntagChunkPayloadSize(t), // Chameleon, before the card's own CC is read
    webNfcChunkPayload(t), // Web NFC, factory CC
  ]),
  mifarePayloadSize('1k'),
  mifarePayloadSize('4k'),
];
const names = ['a.jpg', 'IMG_1234.jpg', 'ü'.repeat(200) + '.jpg', 'x'.repeat(400)];

test('wrapper bytes match wrapWithFilename, including the 255-byte cap', () => {
  for (const n of [...names, '', 'héllo.jpg']) {
    assert.equal(filenameWrapperBytes(n), wrapWithFilename(new Uint8Array(0), n).length);
  }
  assert.equal(filenameWrapperBytes('x'.repeat(400)), 257);
});

test('budget plus wrapper and 44 B never exceed tags x payload, and the estimate agrees', async () => {
  assert.equal(ENCRYPTION_OVERHEAD, 44);
  for (const payloadSize of payloads) {
    for (const fileName of names) {
      for (const tags of [1, 2, 5, 12]) {
        const bytes = photoByteBudget({ tags, payloadSize, fileName });
        assert.equal(bytes, tags * payloadSize - filenameWrapperBytes(fileName) - ENCRYPTION_OVERHEAD);
        if (bytes <= 0) continue;
        assert.ok(bytes + filenameWrapperBytes(fileName) + ENCRYPTION_OVERHEAD <= tags * payloadSize);
        const n = await estimateCardCount(new Uint8Array(bytes), fileName, {
          compress: false,
          encrypted: true,
          payloadSize,
        });
        assert.ok(n <= tags);
        assert.equal(tagsNeeded(bytes + filenameWrapperBytes(fileName) + ENCRYPTION_OVERHEAD, payloadSize), n);
      }
    }
  }
});

test('tagsNeeded rounds up', () => {
  assert.equal(tagsNeeded(1, 100), 1);
  assert.equal(tagsNeeded(100, 100), 1);
  assert.equal(tagsNeeded(101, 100), 2);
});
