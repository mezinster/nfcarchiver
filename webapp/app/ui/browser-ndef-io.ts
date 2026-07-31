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

/** The three NDEFReader members this file touches — not the full DOM lib.dom surface.
 *
 * `onreading` is written via the method-shorthand-in-object-type trick (extract
 * the member type instead of declaring the field with a function-type literal)
 * so the parameter is checked bivariantly rather than contravariantly. Without
 * it, `strictFunctionTypes` would reject any test double whose synthetic event
 * type is narrower than `NdefReadingEventLike` — exactly the kind of fake this
 * interface exists to make possible under node --test. */
export interface NdefReaderLike {
  scan(options: { signal: AbortSignal }): Promise<void>;
  onreading: { bivarianceHack(event: NdefReadingEventLike): void }['bivarianceHack'] | null;
  onreadingerror: ((event: unknown) => void) | null;
  write(message: { records: NdefRecordInit[] }): Promise<void>;
}

export function webNfcAvailable(): boolean {
  return typeof (globalThis as { NDEFReader?: unknown }).NDEFReader === 'function';
}

/** How long a reading with no waiter stays usable. Covers the few-millisecond
 *  gap between one card completing and the loop asking for the next; anything
 *  older would be a tap from a different moment replayed into this operation. */
const BUFFER_MS = 2000;

export class BrowserNdefIO implements NdefIO {
  /** Injectable so this file is testable under node --test, where NDEFReader
   *  does not exist. Production passes nothing. */
  constructor(
    private readonly makeReader: () => NdefReaderLike = () => {
      const Ctor = (globalThis as { NDEFReader?: new () => NdefReaderLike }).NDEFReader;
      if (Ctor === undefined) throw new Error('Web NFC is not available in this browser');
      return new Ctor();
    },
  ) {}

  private reader: NdefReaderLike | null = null;
  private scanning: AbortController | null = null;
  private waiter: { resolve: (r: NdefReading) => void; reject: (e: unknown) => void } | null = null;
  private buffered: { reading: NdefReading; at: number } | null = null;

  async start(): Promise<void> {
    if (this.reader !== null) throw new Error('A scan is already in progress');
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
      this.buffered = { reading, at: Date.now() };
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
    this.reader = reader;
    this.scanning = ac;
  }

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (this.reader === null) throw new Error('Scan not started');
    if (this.waiter !== null) throw new Error('Already waiting for a reading');
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');

    const buffered = this.buffered;
    this.buffered = null;
    if (buffered !== null && Date.now() - buffered.at <= BUFFER_MS) return buffered.reading;

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
