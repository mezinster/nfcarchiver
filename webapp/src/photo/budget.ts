import { MAX_FILENAME_BYTES } from '../filename.js';
import { ENCRYPTION_OVERHEAD } from '../crypto.js';

/** Bytes the filename wrapper adds: 2-byte length plus the UTF-8 name, capped at 255 (see wrapWithFilename). */
export function filenameWrapperBytes(name: string): number {
  return 2 + Math.min(new TextEncoder().encode(name).length, MAX_FILENAME_BYTES);
}

/** Number of tags needed for `bytes` of archived stream. */
export function tagsNeeded(bytes: number, payloadSize: number): number {
  return Math.ceil(bytes / payloadSize);
}

/**
 * Bytes a photo may occupy so that, with the filename wrapper and the
 * encryption overhead reserved, it still fits `tags` tags. May be <= 0.
 */
export function photoByteBudget(opts: { tags: number; payloadSize: number; fileName: string }): number {
  return opts.tags * opts.payloadSize - filenameWrapperBytes(opts.fileName) - ENCRYPTION_OVERHEAD;
}

/** `photo-yyyyMMdd-HHmmss.jpg` when no name, else the base name with `.jpg`. */
export function optimisedFileName(original: string | undefined, now: Date): string {
  if (original === undefined || original === '') {
    const two = (n: number) => String(n).padStart(2, '0');
    const date = String(now.getFullYear()).padStart(4, '0') + two(now.getMonth() + 1) + two(now.getDate());
    const time = two(now.getHours()) + two(now.getMinutes()) + two(now.getSeconds());
    return `photo-${date}-${time}.jpg`;
  }
  const dot = original.lastIndexOf('.');
  const base = dot > 0 ? original.slice(0, dot) : original;
  return `${base}.jpg`;
}
