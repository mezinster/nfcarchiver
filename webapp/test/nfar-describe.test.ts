import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeNfar } from '../src/inspect/nfar-describe.js';
import { encodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, HEADER_SIZE, TOTAL_OVERHEAD } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

const ID = new Uint8Array([
  0x96, 0xd4, 0x5d, 0x14, 0xa5, 0xc1, 0x43, 0x56,
  0x8f, 0x05, 0x01, 0xf2, 0x83, 0x0d, 0x77, 0xf9,
]);

function chunkBytes(payload: Uint8Array, flags = 0, chunkIndex = 0, totalChunks = 1): Uint8Array {
  return encodeChunk({ archiveId: ID, totalChunks, chunkIndex, payload, crc32: crc32(payload), flags });
}

test('describes a valid chunk, CRC verified', () => {
  const payload = new TextEncoder().encode('Test');
  const d = describeNfar(chunkBytes(payload, FLAG_COMPRESSED | FLAG_ENCRYPTED));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.version, 1);
  assert.equal(d.archiveId, '96d45d14-a5c1-4356-8f05-01f2830d77f9');
  assert.equal(d.compressed, true);
  assert.equal(d.encrypted, true);
  assert.equal(d.chunkIndex, 0);
  assert.equal(d.totalChunks, 1);
  assert.equal(d.payloadSize, 4);
  assert.equal(d.totalLength, 36);
  assert.equal(d.crcValid, true);
  assert.deepEqual(d.warnings, []);
});

test('a partial buffer describes the header with CRC status unknown', () => {
  // Only the 28-byte header has been read so far — the CRC tail has not arrived.
  const full = chunkBytes(new TextEncoder().encode('Test'));
  const d = describeNfar(full.subarray(0, HEADER_SIZE));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.payloadSize, 4);
  assert.equal(d.crcStored, null);
  assert.equal(d.crcComputed, null);
  assert.equal(d.crcValid, null, 'unknown must be null, never false — false would read as corruption');
});

test('a blank card reports a magic mismatch, not an exception', () => {
  const d = describeNfar(new Uint8Array(32));
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /magic mismatch/);
  assert.match(d.reason, /4E 46 41 52/);
});

test('an unsupported version is reported by number', () => {
  const bytes = chunkBytes(new Uint8Array([1, 2, 3]));
  bytes[4] = 9;
  const d = describeNfar(bytes);
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /version 9/);
});

test('too few bytes to judge is reported as such', () => {
  const d = describeNfar(new Uint8Array([0x4e, 0x46]));
  assert.equal(d.present, false);
  if (d.present) return;
  assert.match(d.reason, /only 2 bytes/);
});

test('a payload size larger than the card warns but still describes', () => {
  const bytes = chunkBytes(new Uint8Array([1, 2, 3]));
  new DataView(bytes.buffer).setUint16(26, 4000); // absurd payload size
  const d = describeNfar(bytes, 752);
  assert.equal(d.present, true, 'a bad length must not hide the rest of the header');
  if (!d.present) return;
  assert.equal(d.payloadSize, 4000);
  assert.ok(d.warnings.some((w) => /exceeds/.test(w)), JSON.stringify(d.warnings));
  assert.equal(d.crcValid, null, 'the declared tail is past the buffer, so CRC is unknown');
});

test('with no capacity argument, a declared length that would exceed Mifare capacity warns of nothing', () => {
  // A full NTAG216 chunk legitimately runs 828-844 B, well past the 752 B
  // Mifare Classic 1K capacity. Without an explicit capacityBytes, this must
  // not print a false corruption warning on the medium where that size is
  // legal — this is the regression guard for that bug.
  const bytes = chunkBytes(new Uint8Array([1, 2, 3]));
  new DataView(bytes.buffer).setUint16(26, 844 - TOTAL_OVERHEAD); // totalLength 844
  const d = describeNfar(bytes);
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.totalLength, 844);
  assert.ok(!d.warnings.some((w) => /exceeds/.test(w)), JSON.stringify(d.warnings));
});

test('a corrupted payload reports crcValid false', () => {
  const bytes = chunkBytes(new TextEncoder().encode('Test'));
  bytes[HEADER_SIZE]! ^= 0xff; // flip a payload byte, leave the stored CRC alone
  const d = describeNfar(bytes);
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.equal(d.crcValid, false);
  assert.notEqual(d.crcStored, d.crcComputed);
});

test('unknown flag bits are warned about', () => {
  const d = describeNfar(chunkBytes(new Uint8Array([1]), 0x80));
  assert.equal(d.present, true);
  if (!d.present) return;
  assert.ok(d.warnings.some((w) => /unknown flag/.test(w)), JSON.stringify(d.warnings));
});
