/**
 * The browser's JPEG encoder session: the only DOM-touching part of the photo
 * optimiser. Decodes once with the browser's own decoder (HEIC only where the
 * browser has one, i.e. Safari), orientation baked in, then encodes per
 * (maxSide, quality) on a white background. Canvas output carries no EXIF/GPS;
 * stripJpegMetadata runs as a second safeguard, as in the app.
 *
 * Memory: iOS Safari caps one canvas at ~16.7 MP and limits canvas memory in
 * total, while a fit walks from the original side down through the presets.
 * So at most MAX_LIVE_CANVASES scaled canvases are alive, none is created
 * above MAX_CANVAS_PIXELS, and a canvas that can't be made or encoded throws
 * SideTooLargeError — "doesn't fit" for that side, not "can't be read".
 * Only a failure of createImageBitmap is a PhotoDecodeError.
 */
import type { JpegEncoderSession } from '../../src/photo/fit.js';
import { stripJpegMetadata } from '../../src/photo/jpeg-metadata.js';
import { SideTooLargeError } from './photo-optimiser.js';

/** Below iOS Safari's 16,777,216-pixel limit for one canvas. */
export const MAX_CANVAS_PIXELS = 16_000_000;

/** The fit walks sides in order, so the current and the previous side suffice. */
export const MAX_LIVE_CANVASES = 2;

/** The browser could not decode the picked file. */
export class PhotoDecodeError extends Error {
  constructor() {
    super('Photo could not be decoded');
    this.name = 'PhotoDecodeError';
  }
}

/** Least-recently-used cache that releases what it drops. DOM-free, so it is unit-tested. */
export class BoundedCache<K, V> {
  private readonly map = new Map<K, V>();
  constructor(private readonly limit: number, private readonly release: (v: V) => void) {}

  get(key: K): V | undefined {
    const v = this.map.get(key);
    if (v !== undefined) { this.map.delete(key); this.map.set(key, v); } // most recent last
    return v;
  }

  set(key: K, value: V): void {
    const old = this.map.get(key);
    if (old !== undefined && old !== value) this.release(old);
    this.map.delete(key);
    this.map.set(key, value);
    while (this.map.size > this.limit) {
      const [k, v] = this.map.entries().next().value as [K, V];
      this.map.delete(k);
      this.release(v);
    }
  }

  /** Makes room for one more entry before an allocation. */
  reserve(): void {
    while (this.map.size >= this.limit) {
      const [k, v] = this.map.entries().next().value as [K, V];
      this.map.delete(k);
      this.release(v);
    }
  }

  get size(): number {
    return this.map.size;
  }

  clear(): void {
    for (const v of this.map.values()) this.release(v);
    this.map.clear();
  }
}

/** Pixel size of `width`×`height` scaled so its longest side is `maxSide` (never up). */
export function scaledSize(width: number, height: number, maxSide: number): { w: number; h: number } {
  const longest = Math.max(width, height);
  const side = Math.min(maxSide, longest);
  return {
    w: Math.max(1, Math.round((width * side) / longest)),
    h: Math.max(1, Math.round((height * side) / longest)),
  };
}

type Canvas = HTMLCanvasElement | OffscreenCanvas;

function makeCanvas(w: number, h: number): Canvas {
  if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(w, h);
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

/** Zero-sized canvases give their backing store back at once (Safari counts it until GC otherwise). */
function releaseCanvas(c: Canvas): void {
  c.width = 0;
  c.height = 0;
}

async function toJpeg(canvas: Canvas, quality: number): Promise<Blob> {
  if ('convertToBlob' in canvas) return canvas.convertToBlob({ type: 'image/jpeg', quality });
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('JPEG encoding failed'))), 'image/jpeg', quality);
  });
}

export class CanvasJpegSession implements JpegEncoderSession {
  private readonly scaled = new BoundedCache<number, Canvas>(MAX_LIVE_CANVASES, releaseCanvas);
  private bitmap: ImageBitmap | null;

  private constructor(bitmap: ImageBitmap) {
    this.bitmap = bitmap;
    this.width = bitmap.width;
    this.height = bitmap.height;
  }

  readonly width: number;
  readonly height: number;

  static async open(blob: Blob): Promise<CanvasJpegSession> {
    let bitmap: ImageBitmap;
    try {
      bitmap = await createImageBitmap(blob, { imageOrientation: 'from-image' });
    } catch {
      throw new PhotoDecodeError();
    }
    if (bitmap.width === 0 || bitmap.height === 0) {
      bitmap.close();
      throw new PhotoDecodeError();
    }
    return new CanvasJpegSession(bitmap);
  }

  /** The source drawn at `maxSide` (never upscaled) on white, kept while among the last two sides. */
  private canvasFor(maxSide: number): Canvas {
    const { w, h } = scaledSize(this.width, this.height, maxSide);
    const key = Math.max(w, h);
    const hit = this.scaled.get(key);
    if (hit) return hit;
    const bitmap = this.bitmap;
    if (!bitmap) throw new Error('Session closed');
    if (w * h > MAX_CANVAS_PIXELS) throw new SideTooLargeError();
    this.scaled.reserve(); // free the oldest canvas before allocating a new one
    let canvas: Canvas | null = null;
    try {
      canvas = makeCanvas(w, h);
      const ctx = canvas.getContext('2d') as CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D | null;
      if (!ctx) throw new Error('No 2D context'); // what Safari does when canvas memory runs out
      ctx.fillStyle = '#ffffff'; // JPEG has no alpha: flatten transparency onto white
      ctx.fillRect(0, 0, w, h);
      ctx.imageSmoothingEnabled = true;
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(bitmap, 0, 0, w, h);
    } catch {
      if (canvas) releaseCanvas(canvas);
      throw new SideTooLargeError();
    }
    this.scaled.set(key, canvas);
    return canvas;
  }

  async encode(maxSide: number, quality: number): Promise<Uint8Array> {
    const canvas = this.canvasFor(maxSide);
    let blob: Blob;
    try {
      blob = await toJpeg(canvas, Math.min(Math.max(quality, 1), 100) / 100);
    } catch {
      throw new SideTooLargeError(); // encoder out of memory for this size
    }
    return stripJpegMetadata(new Uint8Array(await blob.arrayBuffer()));
  }

  close(): void {
    this.bitmap?.close();
    this.bitmap = null;
    this.scaled.clear();
  }
}
