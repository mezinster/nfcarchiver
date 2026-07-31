import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { CardReadError, WriteVerifyError, type PresentedTag, type Transport } from '../src/transport/transport.js';
import { ArchiveOrchestrator, type ArchiveIO } from '../app/ui/archive-orchestrator.js';
import { RestoreController } from '../app/controller.js';
import { decodeChunk, encodeChunk } from '../src/chunk.js';
import { Logger } from '../src/log/logger.js';
import { WebNfcTransport } from '../src/transport/web-nfc-transport.js';
import { FakeNdefIO } from './fake-ndef-io.js';
import { NtagType } from '../src/nfc/type2.js';

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

/** `active` is the transport the device bar owns — the loop compares the one it
 *  holds against it, so it must be the very object handed to run(). */
function makeIO(active: Transport, over?: Partial<ArchiveIO>) {
  const statuses: string[] = [];
  let hidden = false;
  const io: ArchiveIO = {
    setStatus: (m) => statuses.push(m),
    showProgress: () => {},
    hideProgress: () => { hidden = true; },
    confirmOverwrite: async () => 'once',
    isConnected: () => true,
    activeTransport: () => active,
    awaitReconnect: async () => { throw new Error('awaitReconnect should not be called in this test'); },
    log: new Logger(),
    ...over,
  };
  return { io, statuses, wasHidden: () => hidden };
}

test('a bad card retries instead of aborting the whole session', async () => {
  const inner = new MockTransport();
  // The 2nd write fails (card yanked / verify mismatch), then the same card is re-tapped.
  const t = new FlakyWriteTransport(inner, 2);
  const { io, wasHidden } = makeIO(t);
  const orch = new ArchiveOrchestrator(io);
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
  let active: Transport = tA;
  const io: ArchiveIO = {
    setStatus: () => {},
    // Drop the connection right after the 2nd card is verified.
    showProgress: (_label, value) => { if (value === 2 && connected) connected = false; },
    hideProgress: () => { throw new Error('must not hide progress — session must not abort'); },
    confirmOverwrite: async () => 'once',
    isConnected: () => connected,
    activeTransport: () => (connected ? active : null),
    awaitReconnect: async () => { connected = true; reconnects += 1; active = tB; return tB; },
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

test('swapping readers mid-archive adopts the new transport instead of spinning on the dead one', async () => {
  // The user switches the target tag type (or the reader) while a write is in
  // progress. device.ts tears the old transport down and installs a new one, so
  // the app never stops being "connected" — only the transport identity changes.
  // Gating on isConnected() alone, the loop kept retrying the torn-down
  // transport, which rejects instantly: an unthrottled spin, no reconnect.
  const data = crypto.getRandomValues(new Uint8Array(1200)); // 3 cards at 420 B
  const ioA = new FakeNdefIO();
  const ioB = new FakeNdefIO();
  const tA = new WebNfcTransport(ioA, NtagType.NTAG215);
  const tB = new WebNfcTransport(ioB, NtagType.NTAG216);
  // connect() isn't wired to start() until Task 3/4 — arm both scans directly.
  await ioA.start();
  await ioB.start();
  ioA.tap('0a:00:00:01');
  ioB.tap('0b:00:00:02');
  ioB.tap('0b:00:00:03');

  let active: Transport = tA;
  let reconnects = 0;
  let statusCalls = 0;
  const io: ArchiveIO = {
    setStatus: () => {
      statusCalls += 1;
      // A retry loop against a dead transport shows a status on every pass; the
      // whole session legitimately needs only a handful.
      if (statusCalls > 40) throw new Error('spin: the loop kept retrying a transport it no longer owns');
    },
    showProgress: (_label, value) => {
      if (value === 1 && active === tA) { void tA.disconnect(); active = tB; }
    },
    hideProgress: () => { throw new Error('must not hide progress — session must not abort'); },
    confirmOverwrite: async () => 'once',
    isConnected: () => true, // never disconnected — only swapped
    activeTransport: () => active,
    awaitReconnect: async () => { reconnects += 1; return active; },
    log: new Logger(),
  };

  await new ArchiveOrchestrator(io).run(tA, { data, fileName: 'blob.bin', compress: false, payloadSize: 420 });

  assert.equal(reconnects, 1, 'adopted the new transport exactly once');
  assert.equal(ioA.writes.length, 1, 'only the pre-swap card went to the outgoing reader');
  assert.equal(ioB.writes.length, 2, 'the remaining cards went to the new reader');
  const indices = [...ioA.writes, ...ioB.writes]
    .map((recs) => decodeChunk(recs[0]!.data!).chunkIndex)
    .sort((a, b) => a - b);
  assert.deepEqual(indices, [0, 1, 2], 'every chunk was written exactly once across the swap');
});

test('a prepare failure aborts cleanly with a message (no unhandled rejection)', async () => {
  const t = new MockTransport();
  const { io, statuses, wasHidden } = makeIO(t);
  const orch = new ArchiveOrchestrator(io);
  // payloadSize 1 over 70000 bytes forces > MAX_CHUNKS (65535) -> createChunks throws in prepare().
  await orch.run(t, { data: new Uint8Array(70000), fileName: 'big.bin', compress: false, payloadSize: 1 });
  assert.equal(wasHidden(), true, 'progress hidden on a prepare failure');
  assert.ok(statuses.some((s) => s.length > 0), 'a human-readable status was shown');
});

test('"overwrite all remaining" prompts once, then overwrites the rest silently', async () => {
  const inner = new MockTransport();
  let prompts = 0;
  const { io } = makeIO(inner, { confirmOverwrite: async () => { prompts += 1; return 'all'; } });
  const orch = new ArchiveOrchestrator(io);

  // Every one of the 3 tapped cards already holds NFAR data, so each would
  // normally raise its own overwrite prompt.
  const existing = encodeChunk({
    archiveId: new Uint8Array(16).fill(9), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  const total = 3; // multiCardData at 720 B/chunk => 3 cards
  // The FIRST card is tapped twice: writeNextCard consumes a tap via awaitTag and
  // then throws OverwriteRequiredError (no write), so the overwrite retry needs
  // the card presented again. Once "overwrite all" is chosen, the remaining
  // already-NFAR cards write on a single tap each (no re-throw).
  inner.enqueueTag(uid(0), existing); // 1st tap → prompt (throws, tag consumed)
  inner.enqueueTag(uid(0), existing); // re-tap → the "overwrite all" retry writes chunk 0
  inner.enqueueTag(uid(1), existing); // overwriteAll set → no prompt, writes chunk 1
  inner.enqueueTag(uid(2), existing); // writes chunk 2 → done

  await orch.run(inner, { data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });

  assert.equal(prompts, 1, 'prompted exactly once; "overwrite all" silenced the rest');

  // All 3 cards were overwritten with the NEW archive (chunk indices 0,1,2).
  const indices: number[] = [];
  for (let i = 0; i < total; i++) {
    inner.enqueueTag(uid(i)); await inner.awaitTag();
    indices.push(decodeChunk(await inner.readChunk()).chunkIndex);
  }
  assert.deepEqual([...indices].sort((a, b) => a - b), [0, 1, 2], 'every card holds a new chunk');
});

test('the write loop stops after repeated identical failures instead of spinning', async () => {
  let attempts = 0;
  const failing = {
    ...new MockTransport(),
    name: 'always-fails',
    async awaitTag() { attempts += 1; throw new CardReadError('boom'); },
  } as unknown as Transport;

  const { io, statuses } = makeIO(failing);
  await new ArchiveOrchestrator(io).run(failing, {
    data: new Uint8Array(50), fileName: 'x.bin', compress: false, payloadSize: 100,
  });

  assert.ok(attempts <= 6, `expected the breaker to stop it, got ${attempts} attempts`);
  assert.ok(statuses.some((s) => s.includes('Stopped after repeated failures')));
});
