import { test } from 'node:test';
import assert from 'node:assert/strict';
import { humanError } from '../app/ui/errors.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError, UnsupportedTagError } from '../src/transport/transport.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { DecryptionError } from '../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../app/controller.js';
import { NdefFormatError } from '../src/nfc/ndef.js';

test('humanError maps each typed error to a plain-language message', () => {
  assert.match(humanError(new CardAuthError('x')), /factory defaults/i);
  assert.match(humanError(new WriteVerifyError('x')), /verification failed/i);
  assert.match(humanError(new CardCapacityError('x')), /smaller than the ones already written/i);
  assert.match(humanError(new TagTimeoutError('x')), /no card detected/i);
  assert.match(humanError(new NfarFormatError('x')), /no nfar archive/i);
  assert.match(humanError(new OverwriteRequiredError('x')), /already holds data/i);
  assert.match(humanError(new PasswordRequiredError('x')), /encrypted/i);
  assert.match(humanError(new DecryptionError('x')), /wrong password/i);
  assert.match(humanError(new UnsupportedTagError('x')), /unsupported tag/i);
  assert.match(humanError(new NdefFormatError('x')), /no nfar ndef/i);
  assert.equal(humanError(new DOMException('Aborted', 'AbortError')), 'Cancelled.');
});

test('humanError falls back to the message for unknown errors', () => {
  assert.equal(humanError(new Error('boom')), 'boom');
  assert.equal(humanError('raw string'), 'raw string');
});
