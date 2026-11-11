/**
 * DOM-free photo optimiser behind a `PhotoOptimiserIO` seam (an encoder-session
 * factory, a clock and a change callback), following the InspectIO pattern so
 * `node --test` covers it without a DOM. A port of the Flutter app's
 * lib/features/photo/presentation/photo_optimiser_provider.dart; the fit
 * itself is src/photo/fit.ts and the budget src/photo/budget.ts.
 */
import { fitToBudget, encodeManual, type JpegEncoderSession, type PhotoFitResult } from '../../src/photo/fit.js';
import { filenameWrapperBytes, optimisedFileName, photoByteBudget, tagsNeeded } from '../../src/photo/budget.js';
import { ENCRYPTION_OVERHEAD } from '../../src/crypto.js';

/** Stepper and slider changes wait this long before re-fitting. */
export const PHOTO_REFIT_DEBOUNCE_MS = 250;

/** Hold-to-repeat: the first repeat comes this long after the press. */
export const HOLD_INITIAL_DELAY_MS = 400;

/** The delay before the next repeat, after `elapsed` ms of holding. */
export function holdIntervalAfter(elapsed: number): number {
  if (elapsed < 1000) return 300;
  if (elapsed < 2000) return 100;
  return 50;
}

/** The step multiplier after `elapsed` ms of holding. */
export function holdMultiplierAfter(elapsed: number): number {
  return elapsed >= 3000 ? 10 : 1;
}

export interface Clock {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

const IMAGE_EXTENSIONS = new Set(['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif']);

/** Whether a picked file goes through the optimiser: an `image/*` type or a photo extension. */
export function isImageFile(name: string, type: string): boolean {
  if (type.startsWith('image/')) return true;
  const dot = name.lastIndexOf('.');
  return dot > 0 && IMAGE_EXTENSIONS.has(name.slice(dot + 1).toLowerCase());
}

/** The result's pixel size: the oriented source scaled so its longest side is `maxSide`, never up. */
export function previewDimensions(width: number, height: number, maxSide: number): { width: number; height: number } {
  const longest = Math.max(width, height);
  if (maxSide >= longest) return { width, height };
  const scale = (v: number) => Math.round((v * maxSide) / longest);
  return { width: scale(width), height: scale(height) };
}

/**
 * Steps once per tap and repeats while held: the first repeat after 400 ms,
 * then every 300 ms; every 100 ms after 1 s, every 50 ms after 2 s, and from
 * 3 s on each step is 10. Elapsed time is the sum of the scheduled delays, so
 * the schedule is exact under a fake clock. A port of RepeatButton.
 */
export class HoldRepeater {
  private timer: unknown = null;
  private elapsed = 0;
  private repeated = false;
  private step = 0;

  constructor(
    private readonly clock: Clock,
    private readonly cb: { onStep(delta: number): void; onHoldStart?(): void; onHoldEnd?(): void },
  ) {}

  press(step: number): void {
    this.stopTimer();
    this.step = step;
    this.repeated = false;
    this.elapsed = HOLD_INITIAL_DELAY_MS;
    this.timer = this.clock.setTimeout(() => this.repeat(), HOLD_INITIAL_DELAY_MS);
  }

  /** Pointer up: a plain tap steps once; a released hold ends without an extra step. */
  release(): void {
    if (this.timer === null && !this.repeated) return; // not pressed
    this.stopTimer();
    if (this.repeated) this.cb.onHoldEnd?.();
    else this.cb.onStep(this.step);
    this.repeated = false;
  }

  /** Pointer cancelled or left: no tap step; a hold that repeated still ends. */
  cancel(): void {
    this.stopTimer();
    if (this.repeated) this.cb.onHoldEnd?.();
    this.repeated = false;
  }

  private repeat(): void {
    if (!this.repeated) {
      this.repeated = true;
      this.cb.onHoldStart?.();
    }
    this.cb.onStep(this.step * holdMultiplierAfter(this.elapsed));
    const next = holdIntervalAfter(this.elapsed);
    this.elapsed += next;
    this.timer = this.clock.setTimeout(() => this.repeat(), next);
  }

  private stopTimer(): void {
    if (this.timer !== null) this.clock.clearTimeout(this.timer);
    this.timer = null;
  }
}

export type PhotoMode = 'auto' | 'manual';
export type PhotoError = 'none' | 'decodeFailed';

export interface PhotoOptimiserState {
  payloadSize: number;
  tags: number;
  /** Tags the untouched original needs (with the encryption reserve); the stepper's upper bound. */
  cap: number;
  mode: PhotoMode;
  manualSide: number | null;
  manualQuality: number | null;
  result: PhotoFitResult | null;
  /** Smallest tag count whose budget fits `result`. */
  needed: number | null;
  /** Oriented source size; 0 until the session is open. */
  width: number;
  height: number;
  busy: boolean;
  error: PhotoError;
  /** The result is not smaller than the original file: Keep original is the better choice. */
  largerThanOriginal: boolean;
}

export interface PhotoOptimiserIO {
  openSession(source: Blob): Promise<JpegEncoderSession>;
  clock: Clock;
  onChange(state: PhotoOptimiserState): void;
  /** English-only diagnostics; never file names or bytes. */
  warn?(msg: string, data?: unknown): void;
}

export type PhotoChoice =
  | { kind: 'optimised'; data: Uint8Array; fileName: string }
  | { kind: 'original' };

/** What the Archive tab's source becomes: Use swaps in the JPEG with GZIP off, Keep original changes nothing. */
export function applyPhotoChoice(
  current: { data: Uint8Array; fileName: string; compress: boolean },
  choice: PhotoChoice,
): { data: Uint8Array; fileName: string; compress: boolean } {
  if (choice.kind === 'original') return current;
  // GZIP only adds bytes to a JPEG.
  return { data: choice.data, fileName: choice.fileName, compress: false };
}

/** Thrown inside a fit that a newer request has superseded. */
class Stale extends Error {}

export class PhotoOptimiser {
  readonly outputName: string;
  private s: PhotoOptimiserState;
  private session: JpegEncoderSession | null = null;
  private disposed = false;
  private debounce: unknown = null;
  private holding = false;
  private gen = 0;
  private chain: Promise<void> = Promise.resolve();
  private readonly autoFits = new Map<string, PhotoFitResult>();

  constructor(
    private readonly io: PhotoOptimiserIO,
    private readonly photo: { source: Blob; fileName: string; originalSize: number; payloadSize: number; now?: Date },
  ) {
    this.outputName = optimisedFileName(photo.fileName, photo.now ?? new Date());
    this.s = {
      payloadSize: photo.payloadSize,
      tags: 1,
      cap: this.capFor(photo.payloadSize),
      mode: 'auto',
      manualSide: null,
      manualQuality: null,
      result: null,
      needed: null,
      width: 0,
      height: 0,
      busy: true,
      error: 'none',
      largerThanOriginal: false,
    };
  }

  get state(): PhotoOptimiserState {
    return this.s;
  }

  private set(patch: Partial<PhotoOptimiserState>): void {
    if (this.disposed) return;
    this.s = { ...this.s, ...patch };
    this.s.largerThanOriginal = this.s.result !== null && this.s.result.bytes.length >= this.photo.originalSize;
    this.io.onChange(this.s);
  }

  private capFor(payloadSize: number): number {
    const bytes = this.photo.originalSize + filenameWrapperBytes(this.photo.fileName) + ENCRYPTION_OVERHEAD;
    return Math.max(1, tagsNeeded(bytes, payloadSize));
  }

  private tagsFor(bytes: number, payloadSize: number): number {
    return tagsNeeded(bytes + filenameWrapperBytes(this.outputName) + ENCRYPTION_OVERHEAD, payloadSize);
  }

  /** Decodes the photo, picks the starting count from a 640 px / q70 probe and runs the first fit. */
  async open(): Promise<void> {
    try {
      const session = await this.io.openSession(this.photo.source);
      if (this.disposed) {
        session.close();
        return;
      }
      this.session = session;
      const longest = Math.max(session.width, session.height);
      const probe = await session.encode(Math.min(640, longest), 70);
      if (this.disposed) return;
      const tags = Math.min(Math.max(this.tagsFor(probe.length, this.s.payloadSize), 1), this.s.cap);
      this.set({ width: session.width, height: session.height, tags });
      this.schedule(true);
    } catch (e) {
      if (!this.disposed) this.fail(e);
    }
  }

  setTags(n: number): void {
    const tags = Math.min(Math.max(Math.round(n), 1), this.s.cap);
    if (tags === this.s.tags) return;
    this.set({ tags });
    this.schedule();
  }

  step(delta: number): void {
    this.setTags(this.s.tags + delta);
  }

  /** A held stepper: steps move the count on screen but fit nothing until endHold. */
  beginHold(): void {
    this.holding = true;
    this.clearDebounce();
    this.gen++; // a fit already under way is stale now
    if (this.session !== null && this.s.error === 'none') this.set({ busy: true });
  }

  endHold(): void {
    if (!this.holding) return;
    this.holding = false;
    this.schedule();
  }

  /** The tag type changed: new cap, count kept under it, re-fit now. */
  setPayloadSize(payloadSize: number): void {
    if (payloadSize === this.s.payloadSize) return;
    const cap = this.capFor(payloadSize);
    this.set({ payloadSize, cap, tags: Math.min(this.s.tags, cap) });
    this.schedule(true);
  }

  /** Switches to manual mode, starting from the current result's settings. */
  setManual(opts: { side?: number; quality?: number }): void {
    if (this.s.error !== 'none' || this.session === null) return;
    const manual = this.s.mode === 'manual';
    this.set({
      mode: 'manual',
      manualSide: opts.side ?? (manual ? this.s.manualSide : null) ?? this.s.result?.maxSide ?? Math.max(this.s.width, this.s.height),
      manualQuality: opts.quality ?? (manual ? this.s.manualQuality : null) ?? this.s.result?.quality ?? 70,
    });
    this.schedule(opts.quality === undefined);
  }

  backToAuto(): void {
    if (this.s.mode === 'auto') return;
    this.set({ mode: 'auto' });
    this.schedule(true);
  }

  /** The optimised JPEG, or null while busy, failed or empty. Ends the optimiser. */
  use(): PhotoChoice | null {
    const r = this.s.result;
    if (this.s.busy || this.s.error !== 'none' || r === null) return null;
    this.dispose();
    return { kind: 'optimised', data: r.bytes, fileName: this.outputName };
  }

  /** Archives the original file untouched. Ends the optimiser. */
  keepOriginal(): PhotoChoice {
    this.dispose();
    return { kind: 'original' };
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.gen++;
    this.clearDebounce();
    const s = this.session;
    this.session = null;
    if (s !== null) {
      try { s.close(); } catch { this.io.warn?.('encoder session close failed'); }
    }
  }

  private clearDebounce(): void {
    if (this.debounce !== null) this.io.clock.clearTimeout(this.debounce);
    this.debounce = null;
  }

  private schedule(now = false): void {
    if (this.session === null || this.s.error !== 'none' || this.disposed) return;
    const gen = ++this.gen;
    this.clearDebounce();
    this.set({ busy: true });
    if (this.holding) return; // endHold schedules the fit
    const run = (): void => {
      this.debounce = null;
      this.chain = this.chain.then(() => this.fit(gen));
    };
    if (now) run();
    else this.debounce = this.io.clock.setTimeout(run, PHOTO_REFIT_DEBOUNCE_MS);
  }

  private isCurrent(gen: number): boolean {
    return gen === this.gen && !this.disposed;
  }

  private async fit(gen: number): Promise<void> {
    const inner = this.session;
    if (inner === null || !this.isCurrent(gen)) return;
    const st = this.s;
    const budget = photoByteBudget({ tags: st.tags, payloadSize: st.payloadSize, fileName: this.outputName });
    // Aborts a superseded search at its next encode instead of running it to the end.
    const guarded: JpegEncoderSession = {
      width: inner.width,
      height: inner.height,
      encode: async (side, q) => {
        if (!this.isCurrent(gen)) throw new Stale();
        const bytes = await inner.encode(side, q);
        if (!this.isCurrent(gen)) throw new Stale();
        return bytes;
      },
      close: () => {},
    };
    try {
      let r: PhotoFitResult;
      if (st.mode === 'auto') {
        const key = `${st.payloadSize}:${st.tags}`;
        const cached = this.autoFits.get(key);
        r = cached ?? (await fitToBudget(guarded, budget));
        if (!cached) this.autoFits.set(key, r);
      } else {
        r = await encodeManual(guarded, { maxSide: st.manualSide!, quality: st.manualQuality!, budget });
      }
      if (!this.isCurrent(gen)) return;
      this.set({ result: r, needed: this.tagsFor(r.bytes.length, st.payloadSize), busy: false });
    } catch (e) {
      if (e instanceof Stale) return;
      if (this.isCurrent(gen)) this.fail(e);
    }
  }

  private fail(e: unknown): void {
    this.io.warn?.('photo optimiser failed', { error: e instanceof Error ? e.name : typeof e });
    this.set({ error: 'decodeFailed', busy: false, result: null, needed: null });
  }
}
