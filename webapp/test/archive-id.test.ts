import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatArchiveId } from '../src/archive-id.js';

test('formats 16 bytes as an 8-4-4-4-12 UUID string', () => {
  const id = Uint8Array.from([
    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
  ]);
  assert.equal(formatArchiveId(id), '01234567-89ab-cdef-1032-547698badcfe');
});
