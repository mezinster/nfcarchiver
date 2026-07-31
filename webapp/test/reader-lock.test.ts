import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ReaderLock } from '../app/ui/reader-lock.js';

test('a free lock can be acquired and reports its owner', () => {
  const lock = new ReaderLock();
  assert.equal(lock.current(), null);
  assert.equal(lock.acquire('scan'), true);
  assert.equal(lock.current(), 'scan');
});

test('a second subsystem cannot acquire a held lock', () => {
  // The production defect: the scan loop holds BrowserNdefIO's single waiter
  // slot, and starting an archive on top of it made every tap fail with
  // "Already waiting for a reading" until the breaker discarded the archive.
  const lock = new ReaderLock();
  lock.acquire('scan');
  assert.equal(lock.acquire('archive'), false);
  assert.equal(lock.current(), 'scan', 'a refused acquire must not steal ownership');
});

test('re-acquiring while already the owner is refused', () => {
  // No caller needs re-entrancy, and allowing it would let one release()
  // free a lock that two call sites believe they hold.
  const lock = new ReaderLock();
  lock.acquire('scan');
  assert.equal(lock.acquire('scan'), false);
});

test('the owner can release, freeing the lock', () => {
  const lock = new ReaderLock();
  lock.acquire('archive');
  lock.release('archive');
  assert.equal(lock.current(), null);
  assert.equal(lock.acquire('scan'), true);
});

test('release by a non-owner is a no-op', () => {
  // The second production defect: readerBusy was a plain boolean written by
  // scan, archive and inspect alike, so whichever finished FIRST cleared it
  // for the others. Observed live — the archive loop's finally re-enabled
  // Disconnect while the scan loop was still running.
  const lock = new ReaderLock();
  lock.acquire('scan');
  lock.release('archive');
  assert.equal(lock.current(), 'scan', 'only the owner may release');
});

test('listeners see every ownership change', () => {
  const lock = new ReaderLock();
  const seen: Array<string | null> = [];
  lock.onChange((owner) => seen.push(owner));
  lock.acquire('scan');
  lock.release('scan');
  assert.deepEqual(seen, ['scan', null]);
});

test('a refused acquire notifies nobody', () => {
  const lock = new ReaderLock();
  lock.acquire('scan');
  const seen: Array<string | null> = [];
  lock.onChange((owner) => seen.push(owner));
  lock.acquire('archive');
  lock.release('archive');
  assert.deepEqual(seen, [], 'no state changed, so no notification');
});

test('unsubscribing stops notifications', () => {
  const lock = new ReaderLock();
  const seen: Array<string | null> = [];
  const off = lock.onChange((owner) => seen.push(owner));
  lock.acquire('scan');
  off();
  lock.release('scan');
  assert.deepEqual(seen, ['scan']);
});
