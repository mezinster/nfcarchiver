import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BrowserNdefIO, type NdefReaderLike } from '../app/ui/browser-ndef-io.js';

/** A stand-in NDEFReader that records how often a scan was armed and lets a
 *  test deliver reading events by hand. `onreading`'s parameter is typed as
 *  the full event shape (not narrowed to what `deliver` happens to send) so
 *  this class satisfies `NdefReaderLike`'s function-type-literal member under
 *  `strictFunctionTypes` without loosening that production type. */
class FakeReader implements NdefReaderLike {
  scanCount = 0;
  onreading: ((e: {
    serialNumber: string;
    message: { records: Array<{ recordType: string; mediaType?: string; data?: DataView }> };
  }) => void) | null = null;
  onreadingerror: ((e: unknown) => void) | null = null;
  failScan: Error | null = null;

  async scan(options: { signal: AbortSignal }): Promise<void> {
    if (this.failScan !== null) throw this.failScan;
    this.scanCount += 1;
    if (options.signal.aborted) throw new DOMException('Aborted', 'AbortError');
  }
  async write(): Promise<void> {}

  deliver(serialNumber: string): void {
    this.onreading?.({ serialNumber, message: { records: [] } });
  }
}

test('many readings are served by a single armed scan', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();

  for (let i = 1; i <= 3; i++) {
    const pending = io.awaitReading();
    reader.deliver(`04:0${i}`);
    const reading = await pending;
    assert.equal(reading.serialNumber, `04:0${i}`);
  }
  assert.equal(reader.scanCount, 1, 'the shipped bug re-armed the scan per read');
});

test('start() rejects when the browser refuses the scan', async () => {
  const reader = new FakeReader();
  reader.failScan = new DOMException('denied', 'NotAllowedError');
  const io = new BrowserNdefIO(() => reader);
  await assert.rejects(() => io.start(), /denied/);
});

test('a reading with nobody waiting is served to the next caller', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  reader.deliver('04:aa');
  assert.equal((await io.awaitReading()).serialNumber, '04:aa');
});

test('two concurrent waits are a programming error', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  const first = io.awaitReading();
  await assert.rejects(() => io.awaitReading(), /already waiting/i);
  reader.deliver('04:bb');
  await first;
});

test('stop() ends the scan and clears the buffer', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  await io.start();
  reader.deliver('04:cc');
  io.stop();
  await assert.rejects(() => io.awaitReading(), /not started/i);
});

test('a second start() while one is in flight is rejected without arming a second scan', async () => {
  const reader = new FakeReader();
  const io = new BrowserNdefIO(() => reader);
  const first = io.start();
  await assert.rejects(() => io.start(), /already in progress/i);
  await first;
  assert.equal(reader.scanCount, 1);
});

test('a buffered reading older than BUFFER_MS is discarded, not replayed', async () => {
  const reader = new FakeReader();
  let clock = 0;
  const io = new BrowserNdefIO(() => reader, () => clock);
  await io.start();

  reader.deliver('04:dd'); // buffered at clock=0, with nobody waiting
  clock = 2001; // BUFFER_MS is 2000ms — this reading is now stale

  const pending = io.awaitReading();
  reader.deliver('04:ee'); // a fresh tap arrives after the wait is armed
  assert.equal((await pending).serialNumber, '04:ee');
});
