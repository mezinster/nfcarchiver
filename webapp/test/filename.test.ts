import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wrapWithFilename, unwrapFilename } from '../src/filename.js';
import { toHex } from './hex.js';

test('wrap produces [2-byte BE length][utf8 name][data] and round-trips', () => {
  const data = new Uint8Array([10, 20, 30]);
  const wrapped = wrapWithFilename(data, 'a.txt'); // 'a.txt' = 5 bytes
  assert.equal(toHex(wrapped.subarray(0, 2)), '0005');
  assert.deepEqual([...wrapped.subarray(2, 7)], [...new TextEncoder().encode('a.txt')]);
  assert.deepEqual([...wrapped.subarray(7)], [10, 20, 30]);
  const un = unwrapFilename(wrapped);
  assert.equal(un.fileName, 'a.txt');
  assert.deepEqual([...un.data], [10, 20, 30]);
});

test('wrap truncates a filename longer than 255 bytes', () => {
  const wrapped = wrapWithFilename(new Uint8Array([1]), 'x'.repeat(300));
  assert.equal(toHex(wrapped.subarray(0, 2)), '00ff'); // 255
  const un = unwrapFilename(wrapped);
  assert.equal(un.fileName, 'x'.repeat(255));
});

test('a UTF-8 filename round-trips by bytes, not chars', () => {
  const name = 'ключ.txt'; // multi-byte
  const wrapped = wrapWithFilename(new Uint8Array([9]), name);
  const expectedLen = new TextEncoder().encode(name).length;
  assert.equal((wrapped[0]! << 8) | wrapped[1]!, expectedLen);
  assert.equal(unwrapFilename(wrapped).fileName, name);
});

test('unwrap returns null filename + original data for non-wrapped inputs', () => {
  // length < 2
  assert.deepEqual(unwrapFilename(new Uint8Array([7])), { fileName: null, data: new Uint8Array([7]) });
  // declared length 0
  const zero = new Uint8Array([0x00, 0x00, 1, 2]);
  assert.equal(unwrapFilename(zero).fileName, null);
  assert.deepEqual([...unwrapFilename(zero).data], [0, 0, 1, 2]);
  // declared length > available bytes
  const short = new Uint8Array([0x00, 0x40, 1, 2]); // says 64 filename bytes, only 2 present
  assert.equal(unwrapFilename(short).fileName, null);
  // invalid UTF-8 in the filename region
  const badUtf8 = new Uint8Array([0x00, 0x02, 0xff, 0xfe, 9, 9]);
  assert.equal(unwrapFilename(badUtf8).fileName, null);
  assert.deepEqual([...unwrapFilename(badUtf8).data], [0x00, 0x02, 0xff, 0xfe, 9, 9]);
});
