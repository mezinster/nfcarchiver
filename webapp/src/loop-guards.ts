/**
 * Guards that keep a retry loop from starving the main thread.
 *
 * A card loop retries on error. If the transport rejects instantly — as the
 * Web NFC adapter did when it re-armed an already-running scan — `continue`
 * produces an unbroken chain of already-rejected promises. Awaiting one of
 * those yields a microtask but never returns to the event loop's task queue,
 * so nothing renders and no input is handled: the browser locks up hard
 * enough that the user cannot even press Stop.
 */

/** Wait out the remainder of `minMs` since `startedAt`. */
export function ensureMinInterval(startedAt: number, minMs: number): Promise<void> {
  const remaining = minMs - (Date.now() - startedAt);
  if (remaining <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, remaining));
}

/**
 * Trips after `limit` consecutive failures of the same kind, so a loop that
 * cannot make progress stops and says why instead of retrying forever.
 *
 * Callers must not record conditions that mean "the user has not tapped yet"
 * — see the exclusion lists at each call site.
 */
export class FailureBreaker {
  constructor(private readonly limit: number = 5) {}

  private lastName: string | null = null;
  private count = 0;

  /** Record a failure. Returns true when the loop should stop. */
  record(errorName: string): boolean {
    if (errorName === this.lastName) {
      this.count += 1;
    } else {
      this.lastName = errorName;
      this.count = 1;
    }
    return this.count >= this.limit;
  }

  reset(): void {
    this.lastName = null;
    this.count = 0;
  }
}
