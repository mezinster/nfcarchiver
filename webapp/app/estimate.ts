/**
 * Estimates how many Mifare Classic 1K cards an archive will take, using the
 * same wrap -> compress-if-smaller -> +encryption-overhead pipeline as a real
 * archive so the count matches what will actually be written.
 */

import { wrapWithFilename } from '../src/filename.js';
import { gzipCompress } from '../src/gzip.js';
import { ENCRYPTION_OVERHEAD } from '../src/crypto.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';

export async function estimateCardCount(
  data: Uint8Array,
  fileName: string,
  opts: { compress: boolean; encrypted: boolean },
): Promise<number> {
  if (data.length === 0) return 0;
  const wrapped = wrapWithFilename(data, fileName);
  let processed = wrapped;
  if (opts.compress) {
    const gz = await gzipCompress(wrapped);
    if (gz.length < wrapped.length) processed = gz;
  }
  const size = processed.length + (opts.encrypted ? ENCRYPTION_OVERHEAD : 0);
  return Math.ceil(size / CARD_PAYLOAD_SIZE);
}
