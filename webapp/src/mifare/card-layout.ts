/**
 * Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K or 4K card.
 * Layout is raw NFAR-native: serialized chunk bytes are written sequentially
 * across the usable blocks (47 on 1K, 215 on 4K) (block 0 and every sector trailer skipped),
 * zero-padding the final block. The NFAR header is self-delimiting, so no
 * per-block framing is added.
 */

import { NFAR_MAGIC, NFAR_VERSION, TOTAL_OVERHEAD, HEADER_SIZE, NfarFormatError } from '../chunk.js';

export const BLOCK_SIZE = 16;

/** Mifare Classic geometry this app understands. */
export type CardSize = '1k' | '4k';

/** Sector trailer = last block of its sector (holds the keys). */
export function isSectorTrailer(block: number): boolean {
  return block < 128 ? block % 4 === 3 : (block - 128) % 16 === 15;
}

/** Sector number of a block on a 4K card (identical to 1K for blocks 0-63). */
export function sectorOf(block: number): number {
  return block < 128 ? Math.floor(block / 4) : 32 + Math.floor((block - 128) / 16);
}

/** First block of `sector` on a 4K card. */
export function firstBlockOfSector(sector: number): number {
  return sector < 32 ? sector * 4 : 128 + (sector - 32) * 16;
}

const usableBelow = (n: number): readonly number[] =>
  Object.freeze(Array.from({ length: n }, (_, b) => b).filter((b) => b !== 0 && !isSectorTrailer(b)));

/** Blocks 0-63 minus block 0 and every sector trailer: 47 blocks. */
export const USABLE_BLOCK_INDEXES: readonly number[] = usableBelow(64);

/** Blocks 0-255 minus block 0 and every sector trailer: 215 blocks. */
export const USABLE_BLOCK_INDEXES_4K: readonly number[] = usableBelow(256);

export const CARD_CAPACITY_BYTES = USABLE_BLOCK_INDEXES.length * BLOCK_SIZE; // 752
export const CARD_PAYLOAD_SIZE = CARD_CAPACITY_BYTES - TOTAL_OVERHEAD; // 720

export function usableBlocks(size: CardSize): readonly number[] {
  return size === '4k' ? USABLE_BLOCK_INDEXES_4K : USABLE_BLOCK_INDEXES;
}

/** 752 (1K) / 3440 (4K). */
export function capacityBytes(size: CardSize): number {
  return usableBlocks(size).length * BLOCK_SIZE;
}

/** Largest chunk payload: capacity minus the NFAR header. */
export function payloadSize(size: CardSize): number {
  return capacityBytes(size) - TOTAL_OVERHEAD;
}

/** Capacity a write may use: 4K only when the user's switch is on, even on a 4K card. */
export function writableCapacity(size: CardSize, allow4k: boolean): number {
  return size === '4k' && allow4k ? capacityBytes('4k') : capacityBytes('1k');
}

export class CardCapacityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardCapacityError';
  }
}

export function chunkToBlocks(
  chunkBytes: Uint8Array,
  size: CardSize = '1k',
): { block: number; data: Uint8Array }[] {
  const capacity = capacityBytes(size);
  if (chunkBytes.length > capacity) {
    throw new CardCapacityError(
      `Chunk is ${chunkBytes.length} bytes; a Mifare Classic ${size === '4k' ? '4K' : '1K'} card holds ${capacity}`,
    );
  }
  const usable = usableBlocks(size);
  const blockCount = Math.ceil(chunkBytes.length / BLOCK_SIZE);
  const out: { block: number; data: Uint8Array }[] = [];
  for (let i = 0; i < blockCount; i++) {
    const data = new Uint8Array(BLOCK_SIZE); // zero-filled -> pads the last block
    data.set(chunkBytes.subarray(i * BLOCK_SIZE, (i + 1) * BLOCK_SIZE));
    out.push({ block: usable[i]!, data });
  }
  return out;
}

export function firstBlockIsNfar(block1: Uint8Array): boolean {
  if (block1.length < NFAR_MAGIC.length + 1) return false;
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (block1[i] !== NFAR_MAGIC[i]) return false;
  }
  return block1[NFAR_MAGIC.length] === NFAR_VERSION;
}

export function nfarTotalLength(header: Uint8Array, size: CardSize = '1k'): number {
  if (!firstBlockIsNfar(header)) {
    throw new NfarFormatError('Not an NFAR card: magic or version mismatch');
  }
  if (header.length < HEADER_SIZE) {
    throw new NfarFormatError(`Header too short: need ${HEADER_SIZE} bytes, got ${header.length}`);
  }
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  const payloadSize = view.getUint16(26); // big-endian, per NFAR header layout
  const total = TOTAL_OVERHEAD + payloadSize;
  const capacity = capacityBytes(size);
  if (total > capacity) {
    throw new NfarFormatError(
      `Declared length ${total} exceeds card capacity ${capacity}; card is corrupt or not NFAR`,
    );
  }
  return total;
}

export function assembleChunkFromBlocks(orderedBlockData: Uint8Array[], totalLength: number): Uint8Array {
  const flat = new Uint8Array(orderedBlockData.length * BLOCK_SIZE);
  orderedBlockData.forEach((b, i) => flat.set(b, i * BLOCK_SIZE));
  return flat.slice(0, totalLength);
}
