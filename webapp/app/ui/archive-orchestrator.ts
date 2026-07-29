/**
 * DOM-free archive write loop behind an injected IO seam, mirroring
 * RestoreOrchestrator. The loop NEVER aborts on a per-card failure: any error
 * from writing one card leaves the session state intact and prompts a re-tap.
 * A reader disconnect pauses on awaitReconnect() and resumes the same session
 * on a fresh transport (see setTransport on the controller). The panel supplies
 * real DOM/browser IO; tests supply a stub IO + MockTransport.
 */
import { ArchiveController, OverwriteRequiredError, type ArchiveRequest } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError, type Transport } from '../../src/transport/transport.js';
import { humanError } from './errors.js';
import type { Logger } from '../../src/log/logger.js';

export interface ArchiveIO {
  setStatus(msg: string): void;
  showProgress(label: string, value: number | null, max: number): void;
  hideProgress(): void;
  confirmOverwrite(): boolean;
  isConnected(): boolean;
  awaitReconnect(): Promise<Transport>;
  log: Logger;
}

export class ArchiveOrchestrator {
  constructor(private readonly io: ArchiveIO) {}

  private render(written: number, total: number, done: boolean): void {
    this.io.showProgress(
      done ? `✓ ${written} of ${total} cards written & verified`
           : `✓ ${written} of ${total} written & verified — tap the next card`,
      written, total,
    );
    this.io.setStatus(done
      ? `Done — wrote and verified ${written} card(s).`
      : `Tap card ${written + 1} of ${total} on the reader…`);
  }

  async run(transport: Transport, req: ArchiveRequest): Promise<void> {
    const ctrl = new ArchiveController(transport);
    let total = await ctrl.prepare(req);
    this.render(0, total, false);
    this.io.log.info('archive', 'Prepared', { cards: total });

    let done = false;
    while (!done) {
      if (!this.io.isConnected()) {
        this.io.setStatus('Reader disconnected — reconnect to resume.');
        this.io.log.warn('archive', 'Reader disconnected — awaiting reconnect');
        ctrl.setTransport(await this.io.awaitReconnect());
        this.io.log.info('archive', 'Reconnected — resuming');
        continue;
      }
      try {
        const res = await ctrl.writeNextCard();
        total = res.progress.total;
        done = res.done;
        this.render(res.progress.written, total, done);
        if (res.rechunkedTo) {
          this.io.setStatus(`Card holds ${res.rechunkedTo.payloadSize} B/chunk — writing ${res.rechunkedTo.total} card(s) instead.`);
        }
      } catch (e) {
        if (!this.io.isConnected()) continue; // disconnect — handled at the loop top
        if (e instanceof TagTimeoutError) { this.io.setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
        if (e instanceof UnsupportedTagError) { this.io.setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); continue; }
        if (e instanceof OverwriteRequiredError) {
          if (this.io.confirmOverwrite()) {
            try {
              const res = await ctrl.writeNextCard(undefined, true);
              total = res.progress.total;
              done = res.done;
              this.render(res.progress.written, total, done);
            } catch (e2) {
              if (!this.io.isConnected()) continue;
              this.io.setStatus(`${humanError(e2)} — re-tap to retry.`);
              this.io.log.warn('archive', 'Overwrite write failed — will retry', { error: String(e2) });
            }
          } else {
            this.io.setStatus('Skipped. Tap a different card…');
          }
          continue;
        }
        // Any other per-card failure (verify/auth/capacity/mid-write I-O): retry, never abort.
        this.io.setStatus(`${humanError(e)} — re-tap to retry.`);
        this.io.log.warn('archive', 'Card write failed — will retry', { error: String(e) });
        continue;
      }
    }
    this.io.log.info('archive', 'Write complete', { cards: total });
  }
}
