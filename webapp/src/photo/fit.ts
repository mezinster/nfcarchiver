/** Deterministic photo auto-fit; a port of lib/features/photo/domain/photo_fit.dart. */

/** Longest-side presets in pixels. "Original" is added by candidateSides. */
export const PHOTO_PRESETS: readonly number[] = [320, 480, 640, 800, 1024, 1280, 1440, 1600, 1920, 2560, 3840];

const QUALITY_HIGH = 95;
const QUALITY_GOOD = 50;
const QUALITY_FLOOR = 30;

/** A decoded image that can be re-encoded at different sizes and qualities. */
export interface JpegEncoderSession {
  width: number;
  height: number;
  encode(maxSide: number, quality: number): Promise<Uint8Array>;
  close(): void;
}

/** Descending longest sides to try: the original, then every preset strictly smaller. Never upscales. */
export function candidateSides(longest: number): number[] {
  return [longest, ...[...PHOTO_PRESETS].reverse().filter((p) => p < longest)];
}

export interface PhotoFitResult {
  maxSide: number;
  quality: number;
  bytes: Uint8Array;
  fits: boolean;
}

/**
 * Largest side reaching quality >= 50, else the largest side fitting at
 * quality >= 30, else the smallest result, unfit.
 */
export async function fitToBudget(s: JpegEncoderSession, budget: number): Promise<PhotoFitResult> {
  const sides = candidateSides(Math.max(s.width, s.height));

  const encodeAt = async (side: number, q: number): Promise<PhotoFitResult> => {
    const bytes = await s.encode(side, q);
    return { maxSide: side, quality: q, bytes, fits: bytes.length <= budget };
  };

  // Highest quality in (lo, hi] that fits, given `known` (at lo) already fits.
  const best = async (side: number, lo: number, hi: number, known: PhotoFitResult): Promise<PhotoFitResult> => {
    let found = known;
    let a = lo + 1;
    let b = hi;
    while (a <= b) {
      const mid = Math.floor((a + b) / 2);
      const r = await encodeAt(side, mid);
      if (r.fits) {
        found = r;
        a = mid + 1;
      } else {
        b = mid - 1;
      }
    }
    return found;
  };

  if (budget <= 0) return encodeAt(sides[sides.length - 1]!, QUALITY_FLOOR);

  for (const side of sides) {
    const r = await encodeAt(side, QUALITY_GOOD);
    if (r.fits) return best(side, QUALITY_GOOD, QUALITY_HIGH, r);
  }
  let last!: PhotoFitResult;
  for (const side of sides) {
    const r = await encodeAt(side, QUALITY_FLOOR);
    last = r;
    if (r.fits) return best(side, QUALITY_FLOOR, QUALITY_GOOD - 1, r);
  }
  return last;
}

/** One encode at the user's chosen settings. */
export async function encodeManual(
  s: JpegEncoderSession,
  opts: { maxSide: number; quality: number; budget: number },
): Promise<PhotoFitResult> {
  const bytes = await s.encode(opts.maxSide, opts.quality);
  return { maxSide: opts.maxSide, quality: opts.quality, bytes, fits: bytes.length <= opts.budget };
}
