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
interface NdefReaderLike {
  scan(options: { signal: AbortSignal }): Promise<void>;
  onreading: ((event: NdefReadingEventLike) => void) | null;
  onreadingerror: ((event: unknown) => void) | null;
  write(message: { records: NdefRecordInit[] }): Promise<void>;
}

export function webNfcAvailable(): boolean {
  return typeof (globalThis as { NDEFReader?: unknown }).NDEFReader === 'function';
}

export class BrowserNdefIO implements NdefIO {
  private reader: NdefReaderLike | null = null;
  private scanning: AbortController | null = null;

  async awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading> {
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');

    const Ctor = (globalThis as { NDEFReader?: new () => NdefReaderLike }).NDEFReader;
    if (Ctor === undefined) throw new Error('Web NFC is not available in this browser');
    this.reader ??= new Ctor();
    const reader = this.reader;

    this.scanning?.abort();
    const ac = new AbortController();
    this.scanning = ac;
    if (opts?.signal) {
      opts.signal.addEventListener('abort', () => ac.abort(), { once: true });
    }

    return new Promise<NdefReading>((resolve, reject) => {
      const timer = opts?.timeoutMs === undefined ? null : setTimeout(() => {
        ac.abort();
        reject(new TagTimeoutError(`No tag presented within ${opts.timeoutMs}ms`));
      }, opts.timeoutMs);

      reader.onreading = (event) => {
        if (timer !== null) clearTimeout(timer);
        resolve({
          serialNumber: event.serialNumber ?? '',
          records: event.message.records.map((rec) => ({
            recordType: rec.recordType,
            mediaType: rec.mediaType,
            data: rec.data === undefined
              ? undefined
              : new Uint8Array(rec.data.buffer, rec.data.byteOffset, rec.data.byteLength),
          })),
        });
      };
      reader.onreadingerror = () => {
        if (timer !== null) clearTimeout(timer);
        reject(new Error('Could not read the tag — hold it still and try again'));
      };
      reader.scan({ signal: ac.signal }).catch(reject);
    });
  }

  async write(records: NdefRecordInit[]): Promise<void> {
    const reader = this.reader;
    if (reader === null) throw new Error('Start a scan before writing');
    try {
      await reader.write({ records });
    } catch (e) {
      // Chrome reports "does not fit" and several hardware refusals as
      // DOMExceptions. Capacity is the one the user can act on, and Web NFC
      // gives us no way to check it in advance.
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
  }
}
