/**
 * Exclusive ownership of the connected reader.
 *
 * Scanning, archiving and card inspection all drive the same physical reader
 * through the same `Transport`, and none of them tolerates a second loop
 * calling `awaitTag()` underneath it. Web NFC makes that explicit —
 * `BrowserNdefIO` holds exactly one waiter and rejects a second with
 * "Already waiting for a reading" — but the hazard is not Web NFC's: over a
 * Chameleon two concurrent loops simply race for tags, which is worse for
 * being silent.
 *
 * Observed in production: a restore scan left running while an archive was
 * started took every tap, so all 16 cards failed and the circuit breaker
 * discarded the archive.
 *
 * This replaces a plain `readerBusy` boolean that all three subsystems wrote.
 * Because a boolean has no notion of who set it, whichever finished FIRST
 * cleared it for the rest — so `release` here is owner-checked and a refused
 * `acquire` changes nothing.
 */

export type ReaderUser = 'scan' | 'archive' | 'inspect';

type Listener = (owner: ReaderUser | null) => void;

export class ReaderLock {
  private owner: ReaderUser | null = null;
  private readonly listeners = new Set<Listener>();

  /** Who holds the reader, or null if it is free. */
  current(): ReaderUser | null {
    return this.owner;
  }

  /** Take the reader. Returns false if anyone already holds it — including
   *  `who` itself: no caller needs re-entrancy, and permitting it would let a
   *  single `release()` free a lock two call sites believe they hold. */
  acquire(who: ReaderUser): boolean {
    if (this.owner !== null) return false;
    this.owner = who;
    this.notify();
    return true;
  }

  /** Release the reader. A non-owner's call is ignored, so the `finally` of a
   *  subsystem that never acquired cannot free someone else's lock. */
  release(who: ReaderUser): void {
    if (this.owner !== who) return;
    this.owner = null;
    this.notify();
  }

  /** Subscribe to ownership changes. Returns an unsubscribe function. */
  onChange(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => { this.listeners.delete(fn); };
  }

  private notify(): void {
    for (const fn of this.listeners) fn(this.owner);
  }
}

/** The app's single reader. Tests construct their own `ReaderLock`. */
export const readerLock = new ReaderLock();
