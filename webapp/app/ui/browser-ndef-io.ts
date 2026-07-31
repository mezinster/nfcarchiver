/**
 * The real Web NFC implementation of NdefIO. Chrome on Android only.
 *
 * Deliberately thin: it exists to keep NDEFReader out of src/ (which must
 * import under node --test) and to translate DOM errors into the app's typed
 * errors. All behaviour worth testing lives in WebNfcTransport.
 */
import type { NdefIO, NdefReading, NdefRecordInit } from '../../src/transport/ndef-io.js';
import { TagTimeoutError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';

/** The one NDEFReadingEvent shape this file reads from. */
interface NdefReadingEventLike {
  serialNumber: string;
  message: { records: Array<{ recordType: string; mediaType?: string; data?: DataView }> };
}

/** The three NDEFReader members this file touches — not the full DOM lib.dom surface. */
export interface NdefReaderLike {
  scan(options: { signal: AbortSignal }): Promise<void>;
  onreading: ((event: NdefReadingEventLike) => void) | null;
  onreadingerror: ((event: unknown) => void) | null;
  write(message: { records: NdefRecordInit[] }): Promise<void>;
}

export function webNfcAvailable(): boolean {
  return typeof (globalThis as { NDEFReader?: unknown }).NDEFReader === 'function';
}

/** How long a reading with no waiter stays usable. Covers the few-millisecond
 *  gap between one card completing and the loop asking for the next; anything
 *  older would be a tap from a different moment replayed into this operation.
 *  This also covers the post-timeout case: after awaitReading() rejects with
 *  TagTimeoutError the scan is still armed (start() only calls scan() once),
 *  so a tap that lands shortly after the timeout is buffered here and served
 *  to the *next* awaitReading() call rather than lost. That is intended. */
const BUFFER_MS = 2000;

export class BrowserNdefIO implements NdefIO {
  /** Both injectable so this file is testable under node --test: NDEFReader
   *  doesn't exist there, and BUFFER_MS staleness needs a fake clock to test
   *  without a real 2-second sleep. Production passes neither. */
  constructor(
    private readonly makeReader: () => NdefReaderLike = () => {
      const Ctor = (globalThis as { NDEFReader?: new () => NdefReaderLike }).NDEFReader;
      if (Ctor === undefined) throw new Error('Web NFC is not available in this browser');
      return new Ctor();
    },
    private readonly now: () => number = Date.now,
  ) {}

  private reader: NdefReaderLike | null = null;
  private scanning: AbortController | null = null;
  // Synchronous re-entrancy guard. `reader` is only assigned after the
  // `await reader.scan(...)` below resolves, so two start() calls issued
  // without awaiting the first would both pass a `this.reader !== null`
  // check and arm two scans on this instance — the exact bug this file
  // exists to prevent. `starting` closes that gap: it is set before the
  // first await, so a second call sees it synchronously and rejects on
  // the spot instead of racing.
  private starting = false;
  // Set by stop(), never cleared: one scan per instance, and once stopped this
  // instance is spent. Without it, a stop() issued while start() is still
  // awaiting reader.scan() sees `scanning`/`reader` still null, aborts nothing,
  // and the pending scan then installs a live armed reader on an instance the
  // caller believes it stopped — a reader left armed after teardown, the exact
  // lifecycle leak this file exists to prevent.
  private stopped = false;
  private waiter: { resolve: (r: NdefReading) => void; reject: (e: unknown) => void } | null = null;
  private buffered: { reading: NdefReading; at: number } | null = null;

  async start(): Promise<void> {
    if (this.reader !== null || this.starting) throw new Error('A scan is already in progress');
    this.starting = true;
    try {
      const reader = this.makeReader();
      const ac = new AbortController();

      reader.onreading = (event) => {
        const reading: NdefReading = {
          serialNumber: event.serialNumber ?? '',
          records: event.message.records.map((rec) => ({
            recordType: rec.recordType,
            mediaType: rec.mediaType,
            data: rec.data === undefined
              ? undefined
              : new Uint8Array(rec.data.buffer, rec.data.byteOffset, rec.data.byteLength),
          })),
        };
        const w = this.waiter;
        if (w !== null) {
          this.waiter = null;
          w.resolve(reading);
          return;
        }
        this.buffered = { reading, at: this.now() };
      };

      reader.onreadingerror = () => {
        const w = this.waiter;
        if (w !== null) {
          this.waiter = null;
          w.reject(new Error('Could not read the tag — hold it still and try again'));
        }
      };

      // The one and only scan for this instance. Re-arming a reader is what froze
      // the browser: it rejects synchronously, and a retry loop then spins.
      await reader.scan({ signal: ac.signal });
      // stop() may have landed while that was in flight. It could not abort a
      // controller it had never seen, so undo the arming here instead of
      // publishing it: abort the scan, detach the handlers, and leave `reader`
      // null so awaitReading/write keep reporting "Scan not started".
      if (this.stopped) {
        ac.abort();
        reader.onreading = null;
        reader.onreadingerror = null;
        return;
      }
      this.reader = reader;
      this.scanning = ac;
    } finally {
      this.starting = false;
    }
  }

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (this.reader === null) throw new Error('Scan not started');
    if (this.waiter !== null) throw new Error('Already waiting for a reading');
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');

    const buffered = this.buffered;
    this.buffered = null;
    if (buffered !== null && this.now() - buffered.at <= BUFFER_MS) return buffered.reading;

    return new Promise<NdefReading>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | null = null;
      const settle = (): void => {
        if (timer !== null) clearTimeout(timer);
        opts?.signal?.removeEventListener('abort', onAbort);
        this.waiter = null;
      };
      const onAbort = (): void => { settle(); reject(new DOMException('Aborted', 'AbortError')); };

      this.waiter = {
        resolve: (r) => { settle(); resolve(r); },
        reject: (e) => { settle(); reject(e); },
      };
      opts?.signal?.addEventListener('abort', onAbort, { once: true });
      if (opts?.timeoutMs !== undefined) {
        timer = setTimeout(() => {
          settle();
          reject(new TagTimeoutError(`No tag presented within ${opts.timeoutMs}ms`));
        }, opts.timeoutMs);
      }
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    const reader = this.reader;
    if (reader === null) throw new Error('Scan not started');
    try {
      await reader.write({ records });
    } catch (e) {
      if (e instanceof DOMException &&
          (e.name === 'NotSupportedError' || e.name === 'NetworkError')) {
        throw new CardCapacityError(
          'The card rejected the write — it may be smaller than the selected tag type',
        );
      }
      throw e;
    }
  }

  stop(): void {
    this.stopped = true;
    this.scanning?.abort();
    this.scanning = null;
    if (this.reader !== null) {
      this.reader.onreading = null;
      this.reader.onreadingerror = null;
      this.reader = null;
    }
    this.waiter?.reject(new DOMException('Aborted', 'AbortError'));
    this.waiter = null;
    this.buffered = null;
  }
}
