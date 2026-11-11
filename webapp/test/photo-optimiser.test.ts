import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PhotoOptimiser,
  HoldRepeater,
  applyPhotoChoice,
  archiveGate,
  isImageFile,
  previewDimensions,
  holdIntervalAfter,
  holdMultiplierAfter,
  PHOTO_REFIT_DEBOUNCE_MS,
  SideTooLargeError,
  type Clock,
  type PhotoOptimiserIO,
  type PhotoOptimiserState,
} from '../app/ui/photo-optimiser.js';
import type { JpegEncoderSession } from '../src/photo/fit.js';
import { photoByteBudget } from '../src/photo/budget.js';
import { MAX_CHUNKS } from '../src/chunk.js';
import { FakeJpegSession } from './fake-jpeg-session.js';
import { BoundedCache, MAX_CANVAS_PIXELS, MAX_LIVE_CANVASES, scaledSize } from '../app/ui/canvas-jpeg.js';

const model = (side: number, q: number) => Math.floor((side * side * q) / 1000);
const PAYLOAD = 720;
const ORIGINAL_SIZE = 3_000_000;
const NAME = 'IMG_1.HEIC';
const OUT = 'IMG_1.jpg';

/** Timers that only fire when the test advances time. */
class FakeClock implements Clock {
  now = 0;
  private timers: { id: number; at: number; fn: () => void }[] = [];
  private next = 1;
  setTimeout(fn: () => void, ms: number): unknown {
    const id = this.next++;
    this.timers.push({ id, at: this.now + ms, fn });
    return id;
  }
  clearTimeout(h: unknown): void {
    this.timers = this.timers.filter((t) => t.id !== h);
  }
  pending(): number {
    return this.timers.length;
  }
  advance(ms: number): void {
    const end = this.now + ms;
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const t = this.timers[0];
      if (!t || t.at > end) break;
      this.timers.shift();
      this.now = t.at;
      t.fn();
    }
    this.now = end;
  }
}

const flush = async (): Promise<void> => {
  for (let i = 0; i < 50; i++) await new Promise((r) => setImmediate(r));
};

function setup(opts: {
  session?: JpegEncoderSession;
  open?: () => Promise<JpegEncoderSession>;
  originalSize?: number;
  payloadSize?: number;
} = {}) {
  const clock = new FakeClock();
  const session = opts.session ?? new FakeJpegSession(4032, 3024, model);
  const states: PhotoOptimiserState[] = [];
  const io: PhotoOptimiserIO = {
    openSession: opts.open ?? (async () => session),
    clock,
    onChange: (s) => states.push(s),
  };
  const opt = new PhotoOptimiser(io, {
    source: new Blob([]),
    fileName: NAME,
    originalSize: opts.originalSize ?? ORIGINAL_SIZE,
    payloadSize: opts.payloadSize ?? PAYLOAD,
  });
  return { opt, clock, session, states };
}

test('isImageFile accepts image types and photo extensions only', () => {
  assert.equal(isImageFile('a.bin', 'image/png'), true);
  assert.equal(isImageFile('IMG_0001.HEIC', ''), true);
  for (const n of ['x.jpg', 'x.jpeg', 'x.png', 'x.heic', 'x.heif', 'x.webp', 'x.gif']) {
    assert.equal(isImageFile(n, 'application/octet-stream'), true, n);
  }
  assert.equal(isImageFile('notes.txt', 'text/plain'), false);
  assert.equal(isImageFile('archive.zip', ''), false);
  assert.equal(isImageFile('jpg', ''), false);
});

test('isImageFile leaves vector, TIFF and icon images to plain archiving', () => {
  assert.equal(isImageFile('logo.svg', 'image/svg+xml'), false);
  assert.equal(isImageFile('scan.tif', 'image/tiff'), false);
  assert.equal(isImageFile('favicon.ico', 'image/x-icon'), false);
  assert.equal(isImageFile('favicon.ico', 'image/vnd.microsoft.icon'), false);
  assert.equal(isImageFile('scan.TIFF', 'IMAGE/TIFF'), false, 'case-insensitive');
  for (const t of ['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif', 'image/avif', 'image/bmp']) {
    assert.equal(isImageFile('x', t), true, t);
  }
});

test('hold schedule: 300 ms, then 100 ms after 1 s, 50 ms after 2 s, x10 from 3 s', () => {
  assert.equal(holdIntervalAfter(400), 300);
  assert.equal(holdIntervalAfter(999), 300);
  assert.equal(holdIntervalAfter(1000), 100);
  assert.equal(holdIntervalAfter(2000), 50);
  assert.equal(holdMultiplierAfter(2999), 1);
  assert.equal(holdMultiplierAfter(3000), 10);
});

test('HoldRepeater: a tap is one step, a hold repeats on the schedule and stops on release', () => {
  const clock = new FakeClock();
  const steps: number[] = [];
  const events: string[] = [];
  const r = new HoldRepeater(clock, {
    onStep: (d) => steps.push(d),
    onHoldStart: () => events.push('start'),
    onHoldEnd: () => events.push('end'),
  });

  r.press(1);
  clock.advance(100);
  r.release();
  assert.deepEqual(steps, [1]);
  assert.deepEqual(events, []);

  steps.length = 0;
  r.press(-1);
  clock.advance(500); // first repeat at 400
  assert.deepEqual(steps, [-1]);
  assert.deepEqual(events, ['start']);
  clock.advance(1000); // t=1500: 700, 1000, 1100 … 1500
  const at1500 = steps.length;
  assert.equal(at1500, 1 + 1 + 1 + 5); // 400, 700, 1000, then every 100 ms to 1500
  clock.advance(2000); // t=3500
  assert.ok(steps.includes(-10), 'steps of 10 after 3 s');
  r.release();
  const n = steps.length;
  clock.advance(5000);
  assert.equal(steps.length, n, 'no steps after release');
  assert.deepEqual(events, ['start', 'end']);
  assert.equal(clock.pending(), 0);
});

test('HoldRepeater: cancel stops a hold without a tap step', () => {
  const clock = new FakeClock();
  const steps: number[] = [];
  const r = new HoldRepeater(clock, { onStep: (d) => steps.push(d) });
  r.press(1);
  clock.advance(100);
  r.cancel();
  clock.advance(1000);
  assert.deepEqual(steps, []);
});

test('auto fit on open: starting count from the 640/q70 probe, best fit for that budget', async () => {
  const { opt, session, states } = setup();
  await opt.open();
  await flush();
  const s = opt.state;
  assert.equal(s.width, 4032);
  assert.equal(s.height, 3024);
  // Probe 640²·70/1000 = 28672 B → ceil((28672 + 11 + 44) / 720) = 40 tags.
  assert.equal(s.tags, 40);
  assert.equal(s.cap, Math.ceil((ORIGINAL_SIZE + 2 + NAME.length + 44) / PAYLOAD));
  assert.equal(s.mode, 'auto');
  assert.equal(s.busy, false);
  assert.equal(s.error, 'none');
  assert.ok(s.result);
  assert.equal(s.result.fits, true);
  assert.equal(s.result.maxSide, 640);
  assert.equal(s.result.quality, 70);
  assert.ok(s.result.bytes.length <= photoByteBudget({ tags: 40, payloadSize: PAYLOAD, fileName: OUT }));
  assert.equal(s.needed, 40);
  assert.equal(s.largerThanOriginal, false);
  assert.equal(opt.outputName, OUT);
  assert.deepEqual((session as FakeJpegSession).calls[0], { maxSide: 640, quality: 70 });
  assert.ok(states.length > 0, 'state changes are pushed');
});

test('the cap never exceeds the NFAR maximum of 65,535 cards', async () => {
  // 1 GB on a 144 B payload would need millions of cards.
  const { opt, clock } = setup({ originalSize: 1_000_000_000, payloadSize: 144 });
  assert.equal(opt.state.cap, MAX_CHUNKS);
  opt.setPayloadSize(100);
  assert.equal(opt.state.cap, MAX_CHUNKS);
  opt.setTags(1_000_000);
  assert.equal(opt.state.tags, MAX_CHUNKS);
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  opt.dispose();
});

test('starting count is clamped to the cap the original needs', async () => {
  // A tiny original: 1 tag. The probe would need far more.
  const { opt } = setup({ originalSize: 100 });
  await opt.open();
  await flush();
  assert.equal(opt.state.cap, 1);
  assert.equal(opt.state.tags, 1);
});

test('+/- re-fit after the debounce, clamped to [1, cap]', async () => {
  const { opt, clock, session } = setup();
  await opt.open();
  await flush();
  const before = (session as FakeJpegSession).calls.length;

  opt.step(-20);
  assert.equal(opt.state.tags, 20);
  assert.equal(opt.state.busy, true);
  await flush();
  assert.equal((session as FakeJpegSession).calls.length, before, 'nothing encodes before the debounce');
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  assert.equal(opt.state.busy, false);
  assert.ok(opt.state.result!.bytes.length <= photoByteBudget({ tags: 20, payloadSize: PAYLOAD, fileName: OUT }));
  assert.ok(opt.state.result!.maxSide < 640);

  opt.step(-1000);
  assert.equal(opt.state.tags, 1);
  opt.setTags(1_000_000);
  assert.equal(opt.state.tags, opt.state.cap);
});

test('a hold fits once, after release', async () => {
  const { opt, clock, session } = setup();
  await opt.open();
  await flush();
  const calls = session as FakeJpegSession;
  opt.beginHold();
  for (let i = 0; i < 10; i++) opt.step(1);
  clock.advance(2000);
  await flush();
  const during = calls.calls.length;
  assert.equal(opt.state.tags, 50);
  opt.endHold();
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  assert.ok(calls.calls.length > during, 'fits after release');
  assert.equal(opt.state.busy, false);
  assert.ok(opt.state.result!.bytes.length <= photoByteBudget({ tags: 50, payloadSize: PAYLOAD, fileName: OUT }));
});

test('manual, then back to auto', async () => {
  const { opt, clock } = setup();
  await opt.open();
  await flush();
  const auto = opt.state.result!;

  opt.setManual({ side: 1024 });
  assert.equal(opt.state.mode, 'manual');
  assert.equal(opt.state.manualSide, 1024);
  assert.equal(opt.state.manualQuality, auto.quality, 'quality starts from the auto result');
  await flush();
  assert.equal(opt.state.result!.maxSide, 1024);
  assert.equal(opt.state.result!.fits, false);
  // 1024²·70/1000 = 73400 B → ceil((73400 + 55) / 720) = 103
  assert.equal(opt.state.needed, 103);

  opt.setManual({ quality: 30 });
  assert.equal(opt.state.manualSide, 1024, 'side kept');
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  assert.equal(opt.state.result!.quality, 30);

  opt.backToAuto();
  assert.equal(opt.state.mode, 'auto');
  await flush();
  assert.equal(opt.state.result!.maxSide, auto.maxSide);
  assert.equal(opt.state.result!.quality, auto.quality);
});

test('changing the tag type recomputes the cap and re-fits for the new payload', async () => {
  const { opt } = setup();
  await opt.open();
  await flush();
  opt.setPayloadSize(3408);
  assert.equal(opt.state.cap, Math.ceil((ORIGINAL_SIZE + 2 + NAME.length + 44) / 3408));
  assert.equal(opt.state.tags, 40, 'still under the new cap');
  await flush();
  assert.ok(opt.state.result!.bytes.length <= photoByteBudget({ tags: 40, payloadSize: 3408, fileName: OUT }));
  assert.ok(opt.state.result!.maxSide > 640);
});

test('Use hands back the optimised bytes under a .jpg name, with compression off', async () => {
  const { opt, session } = setup();
  await opt.open();
  await flush();
  const bytes = opt.state.result!.bytes;
  const choice = opt.use();
  assert.ok(choice);
  assert.equal((session as FakeJpegSession).closed, true);

  const original = new Uint8Array([1, 2, 3]);
  const next = applyPhotoChoice({ data: original, fileName: NAME, compress: true }, choice);
  assert.equal(next.data, bytes);
  assert.equal(next.fileName, OUT);
  assert.equal(next.compress, false);
});

test('Use is refused while busy or without a result', async () => {
  const { opt } = setup();
  assert.equal(opt.use(), null);
  await opt.open();
  opt.step(-1);
  assert.equal(opt.state.busy, true);
  assert.equal(opt.use(), null);
});

test('Keep original leaves the file, the name and compression as they were', async () => {
  const { opt, session } = setup();
  await opt.open();
  await flush();
  const choice = opt.keepOriginal();
  assert.equal((session as FakeJpegSession).closed, true);
  const original = new Uint8Array([1, 2, 3]);
  const next = applyPhotoChoice({ data: original, fileName: NAME, compress: true }, choice);
  assert.equal(next.data, original);
  assert.equal(next.fileName, NAME);
  assert.equal(next.compress, true);
});

test('decode failure: error state, no result, Use refused, Keep original still works', async () => {
  const { opt } = setup({ open: async () => { throw new Error('decode'); } });
  await opt.open();
  await flush();
  assert.equal(opt.state.error, 'decodeFailed');
  assert.equal(opt.state.busy, false);
  assert.equal(opt.state.result, null);
  assert.equal(opt.use(), null);
  opt.setManual({ side: 640 });
  assert.equal(opt.state.mode, 'auto', 'manual is ignored after a failure');
  assert.equal(opt.keepOriginal().kind, 'original');
});

test('an encode failure after open is the same decode-failed state', async () => {
  let n = 0;
  const s = new FakeJpegSession(4032, 3024, model);
  const failing: JpegEncoderSession = {
    width: s.width, height: s.height,
    encode: async (side, q) => { if (n++ > 0) throw new Error('encode'); return s.encode(side, q); },
    close: () => s.close(),
  };
  const { opt } = setup({ session: failing });
  await opt.open();
  await flush();
  assert.equal(opt.state.error, 'decodeFailed');
});

/** Encodes that resolve only when the test releases them. */
class GatedSession implements JpegEncoderSession {
  readonly width = 4032;
  readonly height = 3024;
  gated = false;
  calls: { maxSide: number; quality: number }[] = [];
  private waiting: (() => void)[] = [];
  closed = false;
  async encode(maxSide: number, quality: number): Promise<Uint8Array> {
    this.calls.push({ maxSide, quality });
    if (this.gated) await new Promise<void>((r) => this.waiting.push(r));
    return new Uint8Array(model(maxSide, quality));
  }
  releaseAll(): void {
    const w = this.waiting;
    this.waiting = [];
    for (const r of w) r();
  }
  close(): void { this.closed = true; }
}

test('stale results are dropped: a superseded fit never lands', async () => {
  const session = new GatedSession();
  const { opt, clock, states } = setup({ session });
  await opt.open();
  await flush();
  const first = opt.state.result!;
  assert.equal(first.maxSide, 640);

  session.gated = true;
  opt.setManual({ side: 4032 }); // fit A: blocks inside its encode
  await flush();
  assert.equal(session.calls.at(-1)!.maxSide, 4032);
  opt.backToAuto(); // fit B supersedes A while A is still encoding
  states.length = 0;
  session.gated = false;
  session.releaseAll();
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();

  assert.ok(states.every((s) => s.result?.maxSide !== 4032), 'the 4032 px manual result was never published');
  assert.equal(opt.state.mode, 'auto');
  assert.equal(opt.state.result!.maxSide, 640);
  assert.equal(opt.state.busy, false);
});

test('a session opened after dispose is closed, and nothing is published', async () => {
  let resolve!: (s: JpegEncoderSession) => void;
  const session = new FakeJpegSession(4032, 3024, model);
  const { opt, states } = setup({ open: () => new Promise((r) => { resolve = r; }) });
  const opening = opt.open();
  opt.dispose();
  const count = states.length;
  resolve(session);
  await opening;
  await flush();
  assert.equal(session.closed, true);
  assert.equal(states.length, count);
});

test('previewDimensions scales the oriented size to the result side, never up', () => {
  assert.deepEqual(previewDimensions(4032, 3024, 640), { width: 640, height: 480 });
  assert.deepEqual(previewDimensions(3024, 4032, 640), { width: 480, height: 640 });
  assert.deepEqual(previewDimensions(800, 600, 4032), { width: 800, height: 600 });
});

/** An encoder that, like iOS Safari's canvas, cannot produce sides above `limit`. */
function cappedSession(limit: number): FakeJpegSession & { refused: number[] } {
  const inner = new FakeJpegSession(8064, 6048, model) as FakeJpegSession & { refused: number[] };
  inner.refused = [];
  const encode = inner.encode.bind(inner);
  inner.encode = async (side: number, q: number) => {
    if (side > limit) { inner.refused.push(side); throw new SideTooLargeError(); }
    return encode(side, q);
  };
  return inner;
}

test('a side the browser cannot encode counts as "doesn\'t fit": auto moves on to a smaller side', async () => {
  const session = cappedSession(4000);
  const { opt, clock } = setup({ session, originalSize: 30_000_000, payloadSize: 3408 });
  await opt.open();
  await flush();
  opt.setTags(1000); // 3.4 MB: the 8064 px original at q50 (3.25 MB) would fit
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  assert.ok(session.refused.includes(8064), 'the original side was tried and refused');
  assert.equal(opt.state.error, 'none');
  assert.equal(opt.state.tooLarge, false);
  assert.equal(opt.state.result!.maxSide, 3840);
  assert.equal(opt.state.result!.fits, true);
});

test('manual Original above the browser limit: a localized "too large" state, not "can\'t be read"', async () => {
  const session = cappedSession(4000);
  const { opt } = setup({ session, originalSize: 30_000_000 });
  await opt.open();
  await flush();
  opt.setManual({ side: 8064 });
  await flush();
  assert.equal(opt.state.error, 'none');
  assert.equal(opt.state.tooLarge, true);
  assert.equal(opt.state.result, null);
  assert.equal(opt.state.busy, false);
  assert.equal(opt.use(), null);

  opt.setManual({ side: 1024 });
  await flush();
  assert.equal(opt.state.tooLarge, false);
  assert.equal(opt.state.result!.maxSide, 1024);
});

test('every side refused: still not a decode failure', async () => {
  const session = cappedSession(100);
  const { opt } = setup({ session });
  await opt.open();
  await flush();
  assert.equal(opt.state.error, 'none');
  assert.equal(opt.state.tags, 1, 'the refused probe starts at one card');
  assert.equal(opt.state.tooLarge, true);
  assert.equal(opt.state.result, null);
});

test('BoundedCache keeps at most the limit alive and releases what it drops', () => {
  assert.equal(MAX_LIVE_CANVASES, 2);
  const released: string[] = [];
  const c = new BoundedCache<number, string>(MAX_LIVE_CANVASES, (v) => released.push(v));
  c.set(4032, 'a');
  c.set(3840, 'b');
  c.set(2560, 'c');
  assert.equal(c.size, 2);
  assert.deepEqual(released, ['a']);
  assert.equal(c.get(3840), 'b'); // now most recent
  c.reserve(); // room for one more: drops the least recent (2560)
  assert.deepEqual(released, ['a', 'c']);
  assert.equal(c.size, 1);
  c.set(1920, 'd');
  c.set(1600, 'e');
  assert.deepEqual(released, ['a', 'c', 'b']);
  c.clear();
  assert.deepEqual(released.sort(), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(c.size, 0);
});

test('a 48 MP original exceeds the canvas pixel cap; 12 MP does not', () => {
  const big = scaledSize(8064, 6048, 8064);
  assert.ok(big.w * big.h > MAX_CANVAS_PIXELS);
  const twelve = scaledSize(4032, 3024, 4032);
  assert.ok(twelve.w * twelve.h <= MAX_CANVAS_PIXELS);
  assert.deepEqual(scaledSize(8064, 6048, 3840), { w: 3840, h: 2880 });
  assert.deepEqual(scaledSize(800, 600, 3840), { w: 800, h: 600 });
});

test('archiveGate: an open file-mode optimiser holds Archive and hides the estimate', () => {
  assert.deepEqual(
    archiveGate({ connected: true, lockOwner: null, mode: 'file', photoOpen: true }),
    { disabled: true, hint: 'photoDecideFirst', showEstimate: false },
  );
  assert.deepEqual(
    archiveGate({ connected: true, lockOwner: null, mode: 'file', photoOpen: false }),
    { disabled: false, hint: null, showEstimate: true },
  );
});

test('archiveGate: text mode is never held by a file-mode optimiser', () => {
  assert.deepEqual(
    archiveGate({ connected: true, lockOwner: null, mode: 'text', photoOpen: true }),
    { disabled: false, hint: null, showEstimate: true },
  );
});

test('archiveGate: no reader or a busy reader still disables; "connect" outranks the photo hint', () => {
  assert.deepEqual(
    archiveGate({ connected: false, lockOwner: null, mode: 'file', photoOpen: true }),
    { disabled: true, hint: 'connectReaderFirst', showEstimate: false },
  );
  assert.deepEqual(
    archiveGate({ connected: false, lockOwner: null, mode: 'text', photoOpen: false }),
    { disabled: true, hint: 'connectReaderFirst', showEstimate: true },
  );
  assert.deepEqual(
    archiveGate({ connected: true, lockOwner: 'restore', mode: 'file', photoOpen: false }),
    { disabled: true, hint: null, showEstimate: true },
  );
});

// ---------- Use optimised photo (N cards) ----------

/** Even the smallest side is ~100 kB, so nothing fits the opening count. */
const hugeSession = () => new FakeJpegSession(4032, 3024, () => 100_000);

/** Opens on a hugeSession and steps down to 5 cards, where nothing fits. */
async function openNothingFits(opts: Parameters<typeof setup>[0] = {}) {
  const h = setup({ session: hugeSession(), ...opts });
  await h.opt.open();
  await flush();
  h.opt.setTags(5);
  h.clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  return h;
}

test('nothing fits: the state names the count to continue with, and useAtNeeded raises it and uses the result', async () => {
  const { opt, session } = await openNothingFits();
  const s = opt.state;
  assert.equal(s.result!.fits, false);
  assert.ok(s.needed! > s.tags);
  assert.equal(s.continueWithCards, s.needed);
  const needed = s.needed!;
  const choice = await opt.useAtNeeded();
  assert.ok(choice);
  assert.equal(choice.kind, 'optimised');
  if (choice.kind === 'optimised') {
    assert.equal(choice.fileName, OUT);
    assert.equal(choice.data.length, 100_000);
    assert.ok(choice.data.length <= photoByteBudget({ tags: needed, payloadSize: PAYLOAD, fileName: OUT }));
  }
  assert.equal(opt.state.tags, needed);
  assert.equal((session as FakeJpegSession).closed, true);
});

test('no continue label when the result fits', async () => {
  const { opt } = setup();
  await opt.open();
  await flush();
  assert.equal(opt.state.continueWithCards, null);
  assert.equal(await opt.useAtNeeded(), null);
});

test('manual and not fitting: continuing keeps the side and quality', async () => {
  const { opt, clock } = setup();
  await opt.open();
  await flush();
  opt.setManual({ side: 2000, quality: 90 });
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  assert.equal(opt.state.result!.fits, false);
  const needed = opt.state.needed!;
  assert.equal(opt.state.continueWithCards, needed);
  const choice = await opt.useAtNeeded();
  assert.ok(choice && choice.kind === 'optimised');
  assert.equal(choice.data.length, model(2000, 90));
  assert.equal(opt.state.tags, needed);
  assert.equal(opt.state.manualSide, 2000);
  assert.equal(opt.state.manualQuality, 90);
});

test('needed above the cap: the count passes the cap, never the NFAR maximum', async () => {
  // A 20 kB original caps at a few dozen cards; a manual 4032 / q100 needs thousands.
  const { opt, clock } = setup({ originalSize: 20_000 });
  await opt.open();
  await flush();
  opt.setManual({ side: 4032, quality: 100 });
  clock.advance(PHOTO_REFIT_DEBOUNCE_MS);
  await flush();
  const { cap, needed } = opt.state;
  assert.ok(needed! > cap);
  assert.equal(opt.state.continueWithCards, Math.min(needed!, MAX_CHUNKS));
  const choice = await opt.useAtNeeded();
  assert.ok(choice);
  assert.equal(opt.state.tags, needed);
  assert.ok(opt.state.cap >= opt.state.tags);
});

test('useAtNeeded: more than the NFAR maximum needed is refused, not clamped into a bad choice', async () => {
  // 1 GB-ish result cannot fit 65,535 cards of 144 B.
  const { opt } = setup({ session: new FakeJpegSession(4032, 3024, () => 20_000_000), payloadSize: 144, originalSize: 30_000_000 });
  await opt.open();
  await flush();
  assert.equal(opt.state.result!.fits, false);
  assert.ok(opt.state.needed! > MAX_CHUNKS);
  assert.equal(await opt.useAtNeeded(), null);
  assert.ok(opt.state.tags <= MAX_CHUNKS);
});

test('useAtNeeded is refused while busy', async () => {
  const { opt } = await openNothingFits();
  opt.step(1); // debounce pending: busy
  assert.equal(opt.state.busy, true);
  assert.equal(await opt.useAtNeeded(), null);
});

test('useAtNeeded: a newer change during its fit makes it return null', async () => {
  const { opt } = await openNothingFits();
  const p = opt.useAtNeeded();
  opt.step(1); // supersedes the fit
  assert.equal(await p, null);
  opt.dispose();
});

test('useAtNeeded: disposed returns null', async () => {
  const { opt } = await openNothingFits();
  const p = opt.useAtNeeded();
  opt.dispose();
  assert.equal(await p, null);
});

test('the too-large stand-in has no count to continue with', async () => {
  const { opt } = setup({ session: cappedSession(100) });
  await opt.open();
  await flush();
  assert.equal(opt.state.continueWithCards, null);
  opt.dispose();
});
