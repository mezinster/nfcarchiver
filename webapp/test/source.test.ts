import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pickSource, TEXT_FILE_NAME } from '../app/source.js';

const file = { bytes: new Uint8Array([1, 2, 3]), name: 'keys.bin' };

test('pickSource returns the chosen file in File mode', () => {
  assert.deepEqual(pickSource('file', file, 'ignored'), { data: file.bytes, fileName: 'keys.bin' });
});

test('pickSource returns nothing in File mode without a file, even if text was typed', () => {
  assert.equal(pickSource('file', null, 'some text'), null);
});

test('pickSource ignores a chosen file in Text mode', () => {
  // The file input is hidden in Text mode; writing it would be invisible to the user.
  assert.equal(pickSource('text', file, ''), null);
  const src = pickSource('text', file, 'note');
  assert.equal(src?.fileName, TEXT_FILE_NAME);
  assert.deepEqual(Array.from(src!.data), Array.from(new TextEncoder().encode('note')));
});

test('pickSource encodes text as UTF-8', () => {
  assert.equal(pickSource('text', null, 'Привет')!.data.length, 12);
});
