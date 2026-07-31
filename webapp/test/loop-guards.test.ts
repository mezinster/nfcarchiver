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

test('a startedAt in the future cannot stretch the wait past minMs', async () => {
  // A backward wall-clock step (NTP correction, or the user changing the clock
  // or timezone mid-scan) leaves startedAt ahead of now. Unclamped this would
  // sleep for the whole skew, deaf to the abort signal — Stop would look dead.
  const before = Date.now();
  await ensureMinInterval(Date.now() + 60_000, 120);
  const waited = Date.now() - before;
  assert.ok(waited < 1000, `wait must be bounded by minMs, waited ${waited}ms`);
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
