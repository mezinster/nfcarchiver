import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encrypt, decrypt, DecryptionError, ENCRYPTION_OVERHEAD } from '../src/crypto.js';

const data = new Uint8Array(100).map((_, i) => (i * 7) % 256);

test('encrypt/decrypt round-trip', async () => {
  const blob = await encrypt(data, 'secret-password');
  assert.equal(blob.length, data.length + ENCRYPTION_OVERHEAD);
  assert.deepEqual(await decrypt(blob, 'secret-password'), data);
});

test('password is trimmed like the Dart implementation', async () => {
  const blob = await encrypt(data, '  padded  ');
  assert.deepEqual(await decrypt(blob, 'padded'), data);
  assert.deepEqual(await decrypt(blob, '\tpadded\n'), data);
});

test('wrong password throws DecryptionError', async () => {
  const blob = await encrypt(data, 'right');
  await assert.rejects(() => decrypt(blob, 'wrong'), DecryptionError);
});

test('tampered ciphertext throws DecryptionError', async () => {
  const blob = await encrypt(data, 'pw');
  blob[ENCRYPTION_OVERHEAD] = blob[ENCRYPTION_OVERHEAD]! ^ 0xff;
  await assert.rejects(() => decrypt(blob, 'pw'), DecryptionError);
});

test('too-short blob throws DecryptionError', async () => {
  await assert.rejects(() => decrypt(new Uint8Array(10), 'pw'), DecryptionError);
});

test('salt and IV are fresh per call', async () => {
  const a = await encrypt(data, 'pw');
  const b = await encrypt(data, 'pw');
  assert.notDeepEqual(a.subarray(0, 28), b.subarray(0, 28));
});
