import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { CardReadError, UnsupportedTagError, WriteVerifyError, type PresentedTag, type Transport } from '../src/transport/transport.js';
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

/** Wraps a MockTransport and rejects the first N taps with UnsupportedTagError,
 *  as the user works through a stack that starts with foreign cards. */
class ForeignTagTransport implements Transport {
  readonly name = 'foreign';
  private taps = 0;
  constructor(private readonly inner: MockTransport, private readonly foreignTaps: number) {}
  connect() { return this.inner.connect(); }
  disconnect() { return this.inner.disconnect(); }
  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    this.taps += 1;
    if (this.taps <= this.foreignTaps) throw new UnsupportedTagError('not an NFAR-capable tag');
    return this.inner.awaitTag(opts);
  }
  peekIsNfar() { return this.inner.peekIsNfar(); }
  readChunk() { return this.inner.readChunk(); }
  writeChunk(bytes: Uint8Array) { return this.inner.writeChunk(bytes); }
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
  // Arm both scans directly rather than via connect(): this test hands the
  // orchestrator two already-live transports, with no device bar to connect them.
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

  const { io, statuses, wasHidden } = makeIO(failing);
  await new ArchiveOrchestrator(io).run(failing, {
    data: new Uint8Array(50), fileName: 'x.bin', compress: false, payloadSize: 100,
  });

  assert.ok(attempts <= 6, `expected the breaker to stop it, got ${attempts} attempts`);
  assert.ok(statuses.some((s) => s.includes('Stopped after repeated failures')));
  // The session has stopped for good — a progress bar frozen mid-count would
  // read as a write still in flight.
  assert.equal(wasHidden(), true, 'progress hidden when the breaker gives up');
});

test('repeated wrong-media taps never trip the archive breaker', async () => {
  // Tapping foreign cards while sorting a stack is normal use, and an
  // unsupported tag can only arise after a real tap, so it can never be the
  // fast-failure spin the breaker exists to stop. Counting it would discard the
  // whole prepared archive — run() builds a fresh controller per press, so the
  // user would have to start again from card 1.
  const inner = new MockTransport();
  const t = new ForeignTagTransport(inner, 6); // more than the breaker's limit of 5
  const { io, statuses, wasHidden } = makeIO(t);
  inner.enqueueTag(uid(0)); // the one good card, tapped after the foreign ones

  await new ArchiveOrchestrator(io).run(t, {
    data: new Uint8Array(50), fileName: 'x.bin', compress: false, payloadSize: 100,
  });

  assert.equal(wasHidden(), false, 'the session survived the foreign taps');
  assert.ok(!statuses.some((s) => s.includes('Stopped after repeated failures')),
    'the breaker must not trip on unsupported tags');
  inner.enqueueTag(uid(0));
  await inner.awaitTag();
  assert.equal(decodeChunk(await inner.readChunk()).chunkIndex, 0, 'the archive still completed');
});

// ---------------------------------------------------------------------------
// Traceability of a stuck write. A multi-card archive that stops making
// progress used to look identical whatever the cause: the status line still
// showed the previous card's tap prompt (render() only runs after a whole card
// completes) and the log held nothing between "Prepared" and "Write complete".
// These three tests pin the boundary reporting that tells the causes apart.
// ---------------------------------------------------------------------------

const twoCardData = crypto.getRandomValues(new Uint8Array(1000)); // incompressible -> 2 cards

test('re-tapping an already-written card says so instead of silently skipping', async () => {
  const inner = new MockTransport();
  const logger = new Logger();
  const { io, statuses } = makeIO(inner, { log: logger });
  const orch = new ArchiveOrchestrator(io);

  inner.enqueueTag(uid(0)); // card 1 written
  inner.enqueueTag(uid(0)); // user puts the SAME card back — no progress possible
  inner.enqueueTag(uid(0)); // and again
  inner.enqueueTag(uid(1)); // finally a fresh card -> archive completes

  const startedAt = Date.now();
  await orch.run(inner, { data: twoCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  const elapsed = Date.now() - startedAt;

  // The UID must be in the message. Cloned Mifare cards share a UID, so a user
  // swapping twins sees a card they believe is new refused over and over — a
  // message without the UID leaves that to be inferred, which is exactly the
  // 90-second silent skip loop observed on hardware on 2026-08-13.
  assert.ok(statuses.some((s) => /already holds/i.test(s) && /A00000/i.test(s)),
    `the user must be told WHICH card is already written; got ${JSON.stringify(statuses)}`);
  assert.ok(logger.snapshot().some((e) => /already written/i.test(e.msg)),
    'the skip must reach the log — it is otherwise invisible');
  // The skip is a SUCCESS return, so it never reaches the catch block's
  // ensureMinInterval. Unpaced, a card left on the reader is an unthrottled
  // poll that renders no change and logs nothing — indistinguishable from a
  // hang, and the exact shape loop-guards.ts exists to prevent. Two skips must
  // therefore cost at least two intervals.
  assert.ok(elapsed >= 500, `two skips must be paced at 250 ms each; took ${elapsed} ms`);
});

test('each card is logged at every boundary so a stall can be located', async () => {
  const inner = new MockTransport();
  const logger = new Logger();
  const { io } = makeIO(inner, { log: logger });

  inner.enqueueTag(uid(0));
  inner.enqueueTag(uid(1));
  await new ArchiveOrchestrator(io).run(inner, {
    data: twoCardData, fileName: 'blob.bin', compress: false, payloadSize: 720,
  });

  const msgs = logger.snapshot().map((e) => e.msg);
  assert.ok(msgs.some((m) => /tag detected/i.test(m)),
    `a tap must be logged, so "no card" is distinguishable from "stuck mid-write"; got ${JSON.stringify(msgs)}`);
  assert.ok(msgs.some((m) => /writing chunk/i.test(m)),
    'the start of a card write must be logged — a stall inside it is otherwise silent');
  assert.equal(msgs.filter((m) => /card written/i.test(m)).length, 2,
    'every completed card must be logged with its UID');
});

test('a write in flight replaces the tap prompt instead of leaving it frozen', async () => {
  const inner = new MockTransport();
  const { io, statuses } = makeIO(inner);

  inner.enqueueTag(uid(0));
  inner.enqueueTag(uid(1));
  await new ArchiveOrchestrator(io).run(inner, {
    data: twoCardData, fileName: 'blob.bin', compress: false, payloadSize: 720,
  });

  // On a Mifare Classic 1K a card write is 94 BLE round trips (47 blocks +
  // 47 verify reads), 15-25 s. Showing "tap the next card" throughout makes a
  // working write and a hung one indistinguishable.
  assert.ok(statuses.some((s) => /writing card/i.test(s)),
    `a write in progress must be visible; got ${JSON.stringify(statuses)}`);
});

test('the overwrite prompt announces itself, so an unanswered dialog is traceable', async () => {
  const inner = new MockTransport();
  const logger = new Logger();
  const existing = encodeChunk({
    archiveId: new Uint8Array(16).fill(9), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  const { io, statuses } = makeIO(inner, { log: logger, confirmOverwrite: async () => 'once' });

  inner.enqueueTag(uid(0), existing); // tap -> prompt (throws, tag consumed)
  inner.enqueueTag(uid(0), existing); // re-tap -> the confirmed write
  inner.enqueueTag(uid(1), existing); // second card, prompted again
  inner.enqueueTag(uid(1), existing);

  await new ArchiveOrchestrator(io).run(inner, {
    data: twoCardData, fileName: 'blob.bin', compress: false, payloadSize: 720,
  });

  assert.ok(logger.snapshot().some((e) => /overwrite/i.test(e.msg)),
    'opening the prompt must be logged — a dialog nobody answers is otherwise a silent hang');
  assert.ok(statuses.some((s) => /waiting for your answer/i.test(s)),
    `the status line must say a prompt is open; got ${JSON.stringify(statuses)}`);
});
