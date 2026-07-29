import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { WriteVerifyError, type PresentedTag, type Transport } from '../src/transport/transport.js';
import { ArchiveOrchestrator, type ArchiveIO } from '../app/ui/archive-orchestrator.js';
import { RestoreController } from '../app/controller.js';
import { Logger } from '../src/log/logger.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
const multiCardData = crypto.getRandomValues(new Uint8Array(2000)); // incompressible -> many cards

/** Wraps a MockTransport and throws WriteVerifyError on the Nth writeChunk (1-based). */
class FlakyWriteTransport implements Transport {
  readonly name = 'flaky';
  private writes = 0;
  constructor(private readonly inner: MockTransport, private readonly failOnWrite: number) {}
  connect() { return this.inner.connect(); }
  disconnect() { return this.inner.disconnect(); }
  awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> { return this.inner.awaitTag(opts); }
  peekIsNfar() { return this.inner.peekIsNfar(); }
  readChunk() { return this.inner.readChunk(); }
  async writeChunk(bytes: Uint8Array): Promise<void> {
    this.writes += 1;
    if (this.writes === this.failOnWrite) throw new WriteVerifyError('simulated verify failure');
    return this.inner.writeChunk(bytes);
  }
}

function makeIO(over?: Partial<ArchiveIO>) {
  const statuses: string[] = [];
  let hidden = false;
  const io: ArchiveIO = {
    setStatus: (m) => statuses.push(m),
    showProgress: () => {},
    hideProgress: () => { hidden = true; },
    confirmOverwrite: () => true,
    isConnected: () => true,
    awaitReconnect: async () => { throw new Error('awaitReconnect should not be called in this test'); },
    log: new Logger(),
    ...over,
  };
  return { io, statuses, wasHidden: () => hidden };
}

test('a bad card retries instead of aborting the whole session', async () => {
  const inner = new MockTransport();
  const { io, wasHidden } = makeIO();
  const orch = new ArchiveOrchestrator(io);

  // The 2nd write fails (card yanked / verify mismatch), then the same card is re-tapped.
  const t = new FlakyWriteTransport(inner, 2);
  const req = { data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 };

  // Pre-tap enough cards: one extra tap of card index 1 covers the retry.
  const total = 3; // multiCardData at 720 B/chunk => 3 cards
  inner.enqueueTag(uid(0));
  inner.enqueueTag(uid(1)); // this write fails
  inner.enqueueTag(uid(1)); // re-tap same card -> retry succeeds
  inner.enqueueTag(uid(2));

  await orch.run(t, req);

  assert.equal(wasHidden(), false, 'progress is never hidden — the session did not abort');
  // All three distinct cards hold real NFAR chunks now.
  for (let i = 0; i < total; i++) {
    inner.enqueueTag(uid(i)); await inner.awaitTag();
    assert.ok((await inner.readChunk()).length > 0, `card ${i} written`);
  }
});

test('a disconnect pauses and resumes the same session on a fresh transport', async () => {
  const original = crypto.getRandomValues(new Uint8Array(2000)); // 3 cards at 720 B
  const tA = new MockTransport();
  const tB = new MockTransport();

  let connected = true;
  let reconnects = 0;
  const io: ArchiveIO = {
    setStatus: () => {},
    // Drop the connection right after the 2nd card is verified.
    showProgress: (_label, value) => { if (value === 2 && connected) connected = false; },
    hideProgress: () => { throw new Error('must not hide progress — session must not abort'); },
    confirmOverwrite: () => true,
    isConnected: () => connected,
    awaitReconnect: async () => { connected = true; reconnects += 1; return tB; },
    log: new Logger(),
  };

  // total === 3 for 2000 incompressible bytes at 720 B/chunk (deterministic).
  // tA presents cards 0 and 1 (written before the drop); tB presents the one
  // remaining card after reconnect. Enqueue EXACTLY the remainder on tB — extra
  // leftover tags would shift the FIFO readback below and return a blank card.
  tA.enqueueTag(uid(0));
  tA.enqueueTag(uid(1));
  tB.enqueueTag(uid(2));

  const orch = new ArchiveOrchestrator(io);
  await orch.run(tA, { data: original, fileName: 'blob.bin', compress: false, payloadSize: 720 });

  assert.equal(reconnects, 1, 'resumed exactly once');

  // Reassemble from the cards actually written across BOTH transports.
  const restoreT = new MockTransport();
  const readBack = async (t: MockTransport, n: number) => {
    t.enqueueTag(uid(n)); await t.awaitTag(); return t.readChunk();
  };
  restoreT.enqueueTag(uid(0), await readBack(tA, 0));
  restoreT.enqueueTag(uid(1), await readBack(tA, 1));
  restoreT.enqueueTag(uid(2), await readBack(tB, 2));

  const rctrl = new RestoreController(restoreT);
  let detected = await rctrl.scanNextCard(new AbortController().signal);
  detected = await rctrl.scanNextCard(new AbortController().signal);
  detected = await rctrl.scanNextCard(new AbortController().signal);
  assert.equal(detected.length, 1);
  assert.equal(detected[0]!.complete, true, 'all 3 chunks present across the two transports');

  const { data } = await rctrl.restore(detected[0]!.archiveId, undefined);
  assert.deepEqual(data, original, 'resumed session restores byte-identically');
});
