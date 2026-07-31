import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mimeForFilename } from '../app/download-mime.js';

test('text files carry an explicit UTF-8 charset', () => {
  // The reported defect: a restored Cyrillic .txt downloaded as an untyped
  // Blob arrives as application/octet-stream, so the Android viewer has no
  // charset to work from, guesses, and mojibakes every non-ASCII byte. The
  // bytes on disk are already correct — this only tells the viewer how to
  // decode them.
  assert.equal(mimeForFilename('text_note.txt'), 'text/plain;charset=utf-8');
  assert.equal(mimeForFilename('notes.md'), 'text/markdown;charset=utf-8');
  assert.equal(mimeForFilename('rows.csv'), 'text/csv;charset=utf-8');
});

test('extensions are matched case-insensitively', () => {
  assert.equal(mimeForFilename('NOTE.TXT'), 'text/plain;charset=utf-8');
});

test('binary formats get their type without a charset', () => {
  // charset is meaningless on a binary type, and JSON is defined as UTF-8 by
  // RFC 8259 — it has no charset parameter at all.
  assert.equal(mimeForFilename('photo.png'), 'image/png');
  assert.equal(mimeForFilename('doc.pdf'), 'application/pdf');
  assert.equal(mimeForFilename('data.json'), 'application/json');
});

test('the last extension wins on a multi-part name', () => {
  assert.equal(mimeForFilename('archive.tar.gz'), 'application/gzip');
});

test('unknown and extensionless names fall back to octet-stream', () => {
  assert.equal(mimeForFilename('payload.zzz'), 'application/octet-stream');
  assert.equal(mimeForFilename('README'), 'application/octet-stream');
});

test('a leading dot is not an extension', () => {
  // '.bashrc'.lastIndexOf('.') === 0 — the name IS the dotfile, not a suffix.
  assert.equal(mimeForFilename('.bashrc'), 'application/octet-stream');
});

test('a trailing dot yields no extension', () => {
  assert.equal(mimeForFilename('weird.'), 'application/octet-stream');
});
