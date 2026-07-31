import { TagTimeoutError } from '../src/transport/transport.js';
import type { NdefIO, NdefReading, NdefRecordInit } from '../src/transport/ndef-io.js';

/**
 * In-memory Web NFC. Queue readings with `tap()`; `write()` replaces the
 * records of the tag most recently presented, mirroring how Chrome writes to
 * the tag still in the field.
 */
export class FakeNdefIO implements NdefIO {
  private queue: NdefReading[] = [];
  private current: NdefReading | null = null;
  writes: NdefRecordInit[][] = [];
  failNextWrite: Error | null = null;

  tap(serialNumber: string, records: NdefReading['records'] = []): void {
    this.queue.push({ serialNumber, records });
  }

  async awaitReading(): Promise<NdefReading> {
    const next = this.queue.shift();
    if (next === undefined) throw new TagTimeoutError('no tag presented');
    this.current = next;
    return next;
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    if (this.failNextWrite !== null) {
      const err = this.failNextWrite;
      this.failNextWrite = null;
      throw err;
    }
    this.writes.push(records);
    if (this.current !== null) {
      this.current.records = records.map((r) => ({
        recordType: r.recordType,
        mediaType: r.mediaType,
        data: r.data,
      }));
      // Re-present the same tag so a read-back or contract re-tap sees it.
      this.queue.unshift(this.current);
    }
  }

  stop(): void {
    this.queue = [];
  }
}
