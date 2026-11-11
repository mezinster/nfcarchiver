/**
 * The browser's JPEG encoder session: the only DOM-touching part of the photo
 * optimiser. Decodes once with the browser's own decoder (HEIC only where the
 * browser has one, i.e. Safari), orientation baked in, then encodes per
 * (maxSide, quality) on a white background. Canvas output carries no EXIF/GPS;
 * stripJpegMetadata runs as a second safeguard, as in the app.
 */
import type { JpegEncoderSession } from '../../src/photo/fit.js';
import { stripJpegMetadata } from '../../src/photo/jpeg-metadata.js';

/** The browser could not decode the picked file. */
export class PhotoDecodeError extends Error {
  constructor() {
    super('Photo could not be decoded');
    this.name = 'PhotoDecodeError';
  }
}

type Canvas = HTMLCanvasElement | OffscreenCanvas;

function makeCanvas(w: number, h: number): Canvas {
  if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(w, h);
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

async function toJpeg(canvas: Canvas, quality: number): Promise<Blob> {
  if ('convertToBlob' in canvas) return canvas.convertToBlob({ type: 'image/jpeg', quality });
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('JPEG encoding failed'))), 'image/jpeg', quality);
  });
}

export class CanvasJpegSession implements JpegEncoderSession {
  private readonly scaled = new Map<number, Canvas>();
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

  /** The source drawn at `maxSide` (never upscaled) on white, cached per side. */
  private canvasFor(maxSide: number): Canvas {
    const longest = Math.max(this.width, this.height);
    const side = Math.min(maxSide, longest);
    const hit = this.scaled.get(side);
    if (hit) return hit;
    const bitmap = this.bitmap;
    if (!bitmap) throw new Error('Session closed');
    const w = Math.max(1, Math.round((this.width * side) / longest));
    const h = Math.max(1, Math.round((this.height * side) / longest));
    const canvas = makeCanvas(w, h);
    const ctx = canvas.getContext('2d') as CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D | null;
    if (!ctx) throw new Error('No 2D canvas context');
    ctx.fillStyle = '#ffffff'; // JPEG has no alpha: flatten transparency onto white
    ctx.fillRect(0, 0, w, h);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(bitmap, 0, 0, w, h);
    this.scaled.set(side, canvas);
    return canvas;
  }

  async encode(maxSide: number, quality: number): Promise<Uint8Array> {
    const blob = await toJpeg(this.canvasFor(maxSide), Math.min(Math.max(quality, 1), 100) / 100);
    return stripJpegMetadata(new Uint8Array(await blob.arrayBuffer()));
  }

  close(): void {
    this.bitmap?.close();
    this.bitmap = null;
    for (const c of this.scaled.values()) { c.width = 0; c.height = 0; }
    this.scaled.clear();
  }
}
