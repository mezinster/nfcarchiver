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
import { ensureMinInterval, FailureBreaker } from '../../src/loop-guards.js';
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
  /** The transport the device bar currently owns, or null. Compared by identity
   *  against the one the loop holds: a reader hand-off can install a new
   *  transport without the app ever reporting a disconnect. */
  activeTransport(): Transport | null;
  /** Resolves with the transport to resume on — immediately if one is already
   *  live (a hand-off completes before the loop notices, so no further
   *  connection event is coming). */
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
    // The transport this loop is driving. A reader hand-off (Connect, Use phone
    // NFC, or a target-tag change under phone NFC) tears this one down and
    // installs another, and the app is CONNECTED again the moment it does — so
    // the connected flag alone cannot tell us our transport went dead. Compare
    // identity: writing on a torn-down transport rejects instantly, which
    // without this check is an unthrottled retry spin that never reconnects.
    let inUse = transport;
    const usable = (): boolean => this.io.isConnected() && this.io.activeTransport() === inUse;
    const breaker = new FailureBreaker();
    while (!done) {
      const iterationStart = Date.now();
      if (!usable()) {
        const swapped = this.io.isConnected();
        this.io.setStatus(swapped ? t.readerSwitchedResume : t.readerDisconnectedResume);
        this.io.log.warn('archive', swapped ? 'Reader swapped — adopting the new transport' : 'Reader disconnected — awaiting reconnect');
        inUse = await this.io.awaitReconnect();
        ctrl.setTransport(inUse);
        this.io.log.info('archive', 'Resuming on the live transport');
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
        breaker.reset();
      } catch (e) {
        if (!usable()) continue; // disconnect or reader swap — handled at the loop top
        // Stopping must be immediate — checked before pacing, mirroring the
        // restore loop's ordering exactly. Unreachable today (writeNextCard is
        // always called with an undefined signal; no Stop control is wired to
        // archive writes), but the moment one is, this keeps it from being
        // delayed by ensureMinInterval and then swallowed into a retry.
        if (e instanceof DOMException && e.name === 'AbortError') {
          this.io.setStatus(t.cancelled);
          this.io.log.info('archive', 'Write cancelled');
          return;
        }
        await ensureMinInterval(iterationStart, 250);
        if (e instanceof TagTimeoutError) { this.io.setStatus(t.noCardTapHold); continue; }
        if (e instanceof OverwriteRequiredError) {
          const choice = await this.io.confirmOverwrite();
          if (choice === 'skip') { this.io.setStatus(t.skippedTapDifferent); continue; }
          if (choice === 'all') { overwriteAll = true; this.io.log.info('archive', 'Overwrite all remaining'); }
          try {
            const res = await ctrl.writeNextCard(undefined, true);
            total = res.progress.total;
            done = res.done;
            this.render(res.progress.written, total, done);
            breaker.reset();
          } catch (e2) {
            if (!usable()) continue;
            this.io.setStatus(t.retryAfter(humanError(e2)));
            this.io.log.warn('archive', 'Overwrite write failed — will retry', { error: String(e2) });
          }
          continue;
        }
        // Waiting for the user is not failing: TagTimeoutError, an overwrite
        // prompt and an abort (above) must never count toward the breaker.
        // Everything else — including an unsupported tag — does: unlike the
        // restore loop, where a pile of cards legitimately contains foreign
        // media, a wrong-media tap during an active write is a genuine
        // failure to make progress (see restore-panel.ts for the mirror case).
        const name = e instanceof Error ? e.name : 'unknown';
        if (breaker.record(name)) {
          this.io.setStatus(t.scanGaveUp(humanError(e)));
          this.io.log.error('archive', 'Stopped after repeated failures', { error: String(e) });
          return;
        }
        if (e instanceof UnsupportedTagError) { this.io.setStatus(t.unsupportedTapOther); continue; }
        // Any other per-card failure (verify/auth/capacity/mid-write I-O): retry, never abort.
        this.io.setStatus(t.retryAfter(humanError(e)));
        this.io.log.warn('archive', 'Card write failed — will retry', { error: String(e) });
        continue;
      }
    }
    this.io.log.info('archive', 'Write complete', { cards: total });
  }
}
