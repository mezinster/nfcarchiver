import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  wrapType2Tlv, readType2Ndef, NtagType, ntagUserBytes, detectNtagType, ntagChunkPayloadSize,
  chunkPayloadForCapacity, ndefCapacityFromCC, ntagFactoryNdefCapacity, webNfcChunkPayload,
} from '../src/nfc/type2.js';
import { encodeNdefMime, NdefFormatError } from '../src/nfc/ndef.js';
import { TOTAL_OVERHEAD } from '../src/chunk.js';

test('short TLV: 0x03, 1-byte length, ndef, 0xFE; round-trips', () => {
  const ndef = new Uint8Array([1, 2, 3, 4]);
  const tlv = wrapType2Tlv(ndef);
  assert.equal(tlv[0], 0x03);
  assert.equal(tlv[1], 4);
  assert.deepEqual([...tlv.subarray(2, 6)], [1, 2, 3, 4]);
  assert.equal(tlv[6], 0xfe);
  assert.deepEqual([...readType2Ndef(tlv)], [1, 2, 3, 4]);
});

test('long TLV: 0x03, 0xFF, 2-byte BE length for ndef >= 255', () => {
  const ndef = new Uint8Array(300).fill(7);
  const tlv = wrapType2Tlv(ndef);
  assert.deepEqual([...tlv.subarray(0, 4)], [0x03, 0xff, 0x01, 0x2c]); // 300 BE
  assert.deepEqual([...readType2Ndef(tlv)], [...ndef]);
});

test('readType2Ndef skips lock/memory TLVs and finds the NDEF TLV', () => {
  const ndef = new Uint8Array([9, 9]);
  // 0x01 (lock) len 2 + two bytes, then the NDEF TLV
  const mem = new Uint8Array([0x01, 0x02, 0xaa, 0xbb, 0x03, 0x02, 9, 9, 0xfe, 0, 0]);
  assert.deepEqual([...readType2Ndef(mem)], [...ndef]);
});

test('readType2Ndef throws when there is no NDEF TLV before the terminator', () => {
  assert.throws(() => readType2Ndef(new Uint8Array([0xfe, 0, 0])), NdefFormatError);
});

test('detectNtagType reads the GET_VERSION storage byte', () => {
  const v = (storage: number) => new Uint8Array([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, storage, 0x03]);
  assert.equal(detectNtagType(v(0x0f)), NtagType.NTAG213);
  assert.equal(detectNtagType(v(0x11)), NtagType.NTAG215);
  assert.equal(detectNtagType(v(0x13)), NtagType.NTAG216);
  assert.equal(detectNtagType(v(0x99)), null);
});

test('ntagChunkPayloadSize is the max payload whose wrapped chunk fits user memory', () => {
  for (const t of [NtagType.NTAG213, NtagType.NTAG215, NtagType.NTAG216]) {
    const p = ntagChunkPayloadSize(t);
    const cap = ntagUserBytes(t);
    // A full chunk of this payload, NDEF+TLV-wrapped, must fit; one more byte must not.
    const wrappedLen = (payload: number) => wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
    assert.ok(wrappedLen(p) <= cap, `${t}: payload ${p} wraps to ${wrappedLen(p)} > ${cap}`);
    assert.ok(wrappedLen(p + 1) > cap, `${t}: payload ${p + 1} should overflow ${cap}`);
    assert.ok(p > 0);
  }
});

test('chunkPayloadForCapacity keeps the whole wrapped chunk within the capacity, and is maximal', () => {
  const wrappedLen = (payload: number) => wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
  for (const cap of [144, 496, 872]) { // the real NTAG213/215/216 CC-declared NDEF areas
    const p = chunkPayloadForCapacity(cap);
    assert.ok(p > 0);
    assert.ok(wrappedLen(p) <= cap, `cap ${cap}: payload ${p} wraps to ${wrappedLen(p)} > ${cap}`);
    assert.ok(wrappedLen(p + 1) > cap, `cap ${cap}: payload ${p + 1} should overflow ${cap}`);
  }
  // The CC areas of NTAG215/216 are below their raw user memory, so the safe
  // payload is strictly smaller than the raw-memory estimate — the bug's crux.
  assert.ok(chunkPayloadForCapacity(496) < ntagChunkPayloadSize(NtagType.NTAG215));
  assert.ok(chunkPayloadForCapacity(872) < ntagChunkPayloadSize(NtagType.NTAG216));
});

test('ndefCapacityFromCC reads MLEN×8 from a valid CC and rejects an invalid one', () => {
  assert.equal(ndefCapacityFromCC(new Uint8Array([0xe1, 0x10, 0x3e, 0x00])), 496); // NTAG215
  assert.equal(ndefCapacityFromCC(new Uint8Array([0xe1, 0x10, 0x6d, 0x00])), 872); // NTAG216
  assert.equal(ndefCapacityFromCC(new Uint8Array([0xe1, 0x10, 0x12, 0x00])), 144); // NTAG213
  assert.equal(ndefCapacityFromCC(new Uint8Array([0x00, 0x00, 0x00, 0x00])), null); // blank/unformatted
  assert.equal(ndefCapacityFromCC(new Uint8Array([0xe1, 0x10])), null); // too short
});

test('ntagFactoryNdefCapacity returns the CC-declared area, not raw memory', () => {
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG213), 144);
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG215), 496);
  assert.equal(ntagFactoryNdefCapacity(NtagType.NTAG216), 872);
});

test('webNfcChunkPayload matches what the Chameleon path writes', () => {
  // The Chameleon reads the real CC and sizes from it. Web NFC cannot, so it
  // assumes the factory value — the two must agree or cards written by the two
  // readers would differ.
  assert.equal(webNfcChunkPayload(NtagType.NTAG215), chunkPayloadForCapacity(496));
  assert.equal(webNfcChunkPayload(NtagType.NTAG215), 420);
});

test('webNfcChunkPayload is never larger than the raw-memory estimate', () => {
  for (const t of [NtagType.NTAG213, NtagType.NTAG215, NtagType.NTAG216]) {
    assert.ok(webNfcChunkPayload(t) <= ntagChunkPayloadSize(t), `${t} overflows`);
  }
});
