import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeNdefMime, decodeNdefMime, NdefFormatError, NDEF_MIME_TYPE } from '../src/nfc/ndef.js';
import { toHex } from './hex.js';

const MIME = new TextEncoder().encode(NDEF_MIME_TYPE);

test('short record: flags 0xD2, type-length 33, 1-byte payload length, then type + payload', () => {
  const payload = new Uint8Array([1, 2, 3]);
  const rec = encodeNdefMime(payload);
  assert.equal(rec[0], 0xd2); // MB|ME|SR|TNF=media
  assert.equal(rec[1], 33); // type length
  assert.equal(rec[2], 3); // short payload length
  assert.equal(toHex(rec.subarray(3, 3 + 33)), toHex(MIME));
  assert.deepEqual([...rec.subarray(3 + 33)], [1, 2, 3]);
  assert.deepEqual([...decodeNdefMime(rec)], [1, 2, 3]);
});

test('long record: flags 0xC2 and a 4-byte big-endian payload length for payload >= 256', () => {
  const payload = new Uint8Array(300).map((_, i) => i % 256);
  const rec = encodeNdefMime(payload);
  assert.equal(rec[0], 0xc2);
  assert.equal(rec[1], 33);
  assert.deepEqual([...rec.subarray(2, 6)], [0x00, 0x00, 0x01, 0x2c]); // 300 BE
  assert.equal(toHex(rec.subarray(6, 6 + 33)), toHex(MIME));
  assert.deepEqual([...decodeNdefMime(rec)], [...payload]);
});

test('decode rejects a non-NFAR record and truncated input', () => {
  const wrongType = encodeNdefMime(new Uint8Array([9]));
  wrongType[3] = 0x78; // corrupt the MIME type's first byte
  assert.throws(() => decodeNdefMime(wrongType), NdefFormatError);
  assert.throws(() => decodeNdefMime(new Uint8Array([0xd2, 33, 5, 1, 2])), NdefFormatError);
});
