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
    // Named so cleanup() can detach it. The caller's signal outlives one call —
    // restore uses a single AbortController for a whole scan session — so a
    // 50-card scan would otherwise leave 50 dead listeners on it.
    const forwardAbort = (): void => ac.abort();
    opts?.signal?.addEventListener('abort', forwardAbort, { once: true });

    return new Promise<NdefReading>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | null = null;

      // Every settlement path — resolve, reject, whichever fires first — runs
      // through here once, so "clear the timer / detach the handlers / free
      // this.scanning" holds by construction instead of by remembering to
      // repeat it at each call site. Safe to invoke more than once: a second
      // call is a no-op (timer already cleared, handlers already null-or-not-
      // ours, and resolve/reject on an already-settled promise is a no-op).
      //
      // A settling wait may only tear down state it still owns: the handlers
      // live on the *shared* reader, so this guard is not optional the way it
      // would be for a private field. Overlapping calls abort the previous
      // AbortController synchronously (this.scanning?.abort() below) but the
      // previous call's own scan().catch(cleanup) doesn't run until a later
      // microtask — by then a newer call may already have installed its own
      // onreading/onreadingerror on this same reader. Nulling them here
      // unconditionally would wipe a newer call's handlers out from under it.
      const cleanup = (): void => {
        if (timer !== null) clearTimeout(timer);
        // Unconditional: the timer and this listener are private to this call
        // (both close over `ac`), unlike the handlers on the shared reader.
        opts?.signal?.removeEventListener('abort', forwardAbort);
        if (this.scanning === ac) {
          reader.onreading = null;
          reader.onreadingerror = null;
          this.scanning = null;
        }
      };

      if (opts?.timeoutMs !== undefined) {
        timer = setTimeout(() => {
          ac.abort();
          cleanup();
          reject(new TagTimeoutError(`No tag presented within ${opts.timeoutMs}ms`));
        }, opts.timeoutMs);
      }

      reader.onreading = (event) => {
        cleanup();
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
        cleanup();
        reject(new Error('Could not read the tag — hold it still and try again'));
      };
      reader.scan({ signal: ac.signal }).catch((e: unknown) => {
        cleanup();
        reject(e);
      });
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
