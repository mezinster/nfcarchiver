import type { JpegEncoderSession } from '../src/photo/fit.js';

/** A JpegEncoderSession whose output length is computed by `size`. */
export class FakeJpegSession implements JpegEncoderSession {
  calls: { maxSide: number; quality: number }[] = [];
  closed = false;
  constructor(
    readonly width: number,
    readonly height: number,
    readonly size: (side: number, quality: number) => number,
  ) {}
  async encode(maxSide: number, quality: number): Promise<Uint8Array> {
    this.calls.push({ maxSide, quality });
    return new Uint8Array(this.size(maxSide, quality));
  }
  close(): void {
    this.closed = true;
  }
}
