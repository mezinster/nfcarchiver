import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BrowserNdefIO, type NdefReaderLike } from '../app/ui/browser-ndef-io.js';

/** A stand-in NDEFReader that records how often a scan was armed and lets a
 *  test deliver reading events by hand. */
class FakeReader implements NdefReaderLike {
  scanCount = 0;
  onreading: ((e: { serialNumber: string; message: { records: [] } }) => void) | null = null;
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
