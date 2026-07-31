import { TagTimeoutError } from '../src/transport/transport.js';
import type { NdefIO, NdefReading, NdefRecordInit } from '../src/transport/ndef-io.js';

/**
 * In-memory Web NFC, modelling the real constraint that made the shipped
 * adapter freeze the browser: exactly one scan may be armed per instance, and
 * awaitReading() never arms one. `scanArmCount` is what the regression test
 * asserts.
 */
export class FakeNdefIO implements NdefIO {
  scanArmCount = 0;
  writes: NdefRecordInit[][] = [];
  failNextWrite: Error | null = null;
  failStart: Error | null = null;

  private started = false;
  private pending: NdefReading[] = [];
  private waiter: ((r: NdefReading) => void) | null = null;
  private current: NdefReading | null = null;

  async start(): Promise<void> {
    if (this.failStart !== null) throw this.failStart;
    if (this.started) throw new Error('A scan is already in progress');
    this.started = true;
    this.scanArmCount += 1;
  }

  /** Simulate a tag entering the field. */
  tap(serialNumber: string, records: NdefReading['records'] = []): void {
    const reading: NdefReading = { serialNumber, records };
    this.current = reading;
    if (this.waiter !== null) {
      const w = this.waiter;
      this.waiter = null;
      w(reading);
      return;
    }
    this.pending.push(reading);
  }

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (!this.started) throw new Error('Scan not started');
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    const buffered = this.pending.shift();
    if (buffered !== undefined) return buffered;
    if (opts?.timeoutMs !== undefined) throw new TagTimeoutError('no tag presented');
    return new Promise<NdefReading>((resolve, reject) => {
      this.waiter = resolve;
      opts?.signal?.addEventListener('abort', () => {
        this.waiter = null;
        reject(new DOMException('Aborted', 'AbortError'));
      }, { once: true });
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    if (this.failNextWrite !== null) {
      const err = this.failNextWrite;
      this.failNextWrite = null;
      throw err;
    }
    this.writes.push(records);
    if (this.current !== null) {
      // Re-present the same tag with its new contents, as a re-tap would.
      this.tap(this.current.serialNumber, records.map((r) => ({
        recordType: r.recordType, mediaType: r.mediaType, data: r.data,
      })));
    }
  }

  stop(): void {
    this.started = false;
    this.pending = [];
    this.waiter = null;
    this.current = null;
  }
}
