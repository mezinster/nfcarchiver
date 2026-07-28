import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Logger, formatLogLine, type LogEntry } from '../src/log/logger.js';

test('formatLogLine is deterministic (UTC time, padded level)', () => {
  const e: LogEntry = { seq: 0, t: 0, level: 'info', cat: 'scan', msg: 'hi' };
  assert.equal(formatLogLine(e), '00:00:00.000 INFO  [scan] hi');
  assert.equal(formatLogLine({ ...e, level: 'error', data: { id: 'x' } }), '00:00:00.000 ERROR [scan] hi {"id":"x"}');
});

test('info appends an entry retrievable via snapshot with monotonic seq', () => {
  const log = new Logger();
  log.info('cat', 'first');
  log.warn('cat', 'second', { n: 2 });
  const s = log.snapshot();
  assert.equal(s.length, 2);
  assert.equal(s[0]!.msg, 'first');
  assert.equal(s[0]!.level, 'info');
  assert.equal(s[1]!.data && (s[1]!.data as { n: number }).n, 2);
  assert.equal(s[1]!.seq, s[0]!.seq + 1);
});

test('ring buffer evicts oldest at capacity', () => {
  const log = new Logger({ capacity: 3 });
  for (let i = 0; i < 5; i++) log.info('c', `m${i}`);
  const msgs = log.snapshot().map((e) => e.msg);
  assert.deepEqual(msgs, ['m2', 'm3', 'm4']);
});

test('subscribe fires on each append; unsubscribe stops it', () => {
  const log = new Logger();
  const seen: string[] = [];
  const off = log.subscribe((e) => seen.push(e.msg));
  log.info('c', 'a');
  off();
  log.info('c', 'b');
  assert.deepEqual(seen, ['a']);
});

test('clear empties the buffer', () => {
  const log = new Logger();
  log.info('c', 'a');
  log.clear();
  assert.equal(log.snapshot().length, 0);
});

test('a throwing subscriber does not break logging or other subscribers', () => {
  const log = new Logger();
  const seen: string[] = [];
  log.subscribe(() => { throw new Error('boom'); });
  log.subscribe((e) => seen.push(e.msg));
  assert.doesNotThrow(() => log.info('c', 'a'));
  assert.deepEqual(seen, ['a']);
});

test('console mirror is off by default and forwards when enabled', () => {
  const calls: string[] = [];
  const orig = console.info;
  console.info = (msg?: unknown) => { calls.push(String(msg)); };
  try {
    const log = new Logger();
    log.info('c', 'silent');
    assert.equal(calls.length, 0);
    log.setMirrorToConsole(true);
    log.info('c', 'loud');
    assert.equal(calls.length, 1);
  } finally {
    console.info = orig;
  }
});
