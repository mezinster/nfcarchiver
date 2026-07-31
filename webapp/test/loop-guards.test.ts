import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ensureMinInterval, FailureBreaker } from '../src/loop-guards.js';

test('ensureMinInterval resolves immediately once the interval has passed', async () => {
  const before = Date.now();
  await ensureMinInterval(Date.now() - 500, 250);
  assert.ok(Date.now() - before < 100, 'should not have waited');
});

test('ensureMinInterval waits out the remainder', async () => {
  const before = Date.now();
  await ensureMinInterval(Date.now(), 120);
  assert.ok(Date.now() - before >= 100, 'should have waited roughly the interval');
});

test('the breaker trips after the limit of identical failures', () => {
  const b = new FailureBreaker(3);
  assert.equal(b.record('CardReadError'), false);
  assert.equal(b.record('CardReadError'), false);
  assert.equal(b.record('CardReadError'), true);
});

test('a different error name restarts the count', () => {
  const b = new FailureBreaker(3);
  b.record('CardReadError');
  b.record('CardReadError');
  assert.equal(b.record('WriteVerifyError'), false, 'a new kind of failure starts over');
  assert.equal(b.record('WriteVerifyError'), false);
});

test('reset clears the count', () => {
  const b = new FailureBreaker(2);
  b.record('CardReadError');
  b.reset();
  assert.equal(b.record('CardReadError'), false);
});
