/**
 * DOM-free archive write loop behind an injected IO seam, following the same
 * orchestrator-behind-an-IO-seam pattern as RestoreOrchestrator (with its own
 * ArchiveIO seam). The loop NEVER aborts on a per-card failure: any error
 * from writing one card leaves the session state intact and prompts a re-tap.
 * A reader disconnect pauses on awaitReconnect() and resumes the same session
 * on a fresh transport (see setTransport on the controller). The panel supplies
 * real DOM/browser IO; tests supply a stub IO + MockTransport.
 */
import { ArchiveController, OverwriteRequiredError, type ArchiveRequest } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError, type Transport } from '../../src/transport/transport.js';
import { humanError } from './errors.js';
import { t } from '../i18n/index.js';
import type { Logger } from '../../src/log/logger.js';

/** The user's answer when a tapped card already holds NFAR data:
 *  'once' = overwrite just this card, 'all' = overwrite this and every
 *  remaining card without asking again, 'skip' = leave it and tap another. */
export type OverwriteChoice = 'once' | 'all' | 'skip';

export interface ArchiveIO {
  setStatus(msg: string): void;
  showProgress(label: string, value: number | null, max: number): void;
  hideProgress(): void;
  confirmOverwrite(): Promise<OverwriteChoice>;
  isConnected(): boolean;
  awaitReconnect(): Promise<Transport>;
  log: Logger;
}

export class ArchiveOrchestrator {
  constructor(private readonly io: ArchiveIO) {}

  private render(written: number, total: number, done: boolean): void {
    this.io.showProgress(
      done ? t.progressDone(written, total) : t.progressWriting(written, total),
      written, total,
    );
    this.io.setStatus(done ? t.archiveDone(written) : t.tapCardOf(written + 1, total));
  }

  async run(transport: Transport, req: ArchiveRequest): Promise<void> {
    const ctrl = new ArchiveController(transport);
    let total: number;
    try {
      total = await ctrl.prepare(req);
    } catch (e) {
      this.io.hideProgress();
      this.io.setStatus(humanError(e));
      this.io.log.error('archive', 'Prepare failed', { error: String(e) });
      return;
    }
    this.render(0, total, false);
    this.io.log.info('archive', 'Prepared', { cards: total });

    let done = false;
    // Once the user picks "overwrite all remaining", every subsequent already-
    // NFAR card is overwritten without prompting (passed straight into
    // writeNextCard so it never even throws OverwriteRequiredError).
    let overwriteAll = false;
    while (!done) {
      if (!this.io.isConnected()) {
        this.io.setStatus(t.readerDisconnectedResume);
        this.io.log.warn('archive', 'Reader disconnected — awaiting reconnect');
        ctrl.setTransport(await this.io.awaitReconnect());
        this.io.log.info('archive', 'Reconnected — resuming');
        continue;
      }
      try {
        const res = await ctrl.writeNextCard(undefined, overwriteAll);
        total = res.progress.total;
        done = res.done;
        this.render(res.progress.written, total, done);
        if (res.rechunkedTo) {
          this.io.setStatus(t.rechunked(res.rechunkedTo.payloadSize, res.rechunkedTo.total));
        }
      } catch (e) {
        if (!this.io.isConnected()) continue; // disconnect — handled at the loop top
        if (e instanceof TagTimeoutError) { this.io.setStatus(t.noCardTapHold); continue; }
        if (e instanceof UnsupportedTagError) { this.io.setStatus(t.unsupportedTapOther); continue; }
        if (e instanceof OverwriteRequiredError) {
          const choice = await this.io.confirmOverwrite();
          if (choice === 'skip') { this.io.setStatus(t.skippedTapDifferent); continue; }
          if (choice === 'all') { overwriteAll = true; this.io.log.info('archive', 'Overwrite all remaining'); }
          try {
            const res = await ctrl.writeNextCard(undefined, true);
            total = res.progress.total;
            done = res.done;
            this.render(res.progress.written, total, done);
          } catch (e2) {
            if (!this.io.isConnected()) continue;
            this.io.setStatus(t.retryAfter(humanError(e2)));
            this.io.log.warn('archive', 'Overwrite write failed — will retry', { error: String(e2) });
          }
          continue;
        }
        // Any other per-card failure (verify/auth/capacity/mid-write I-O): retry, never abort.
        this.io.setStatus(t.retryAfter(humanError(e)));
        this.io.log.warn('archive', 'Card write failed — will retry', { error: String(e) });
        continue;
      }
    }
    this.io.log.info('archive', 'Write complete', { cards: total });
  }
}
