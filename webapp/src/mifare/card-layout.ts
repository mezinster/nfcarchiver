/**
 * Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K card.
 * Layout is raw NFAR-native: serialized chunk bytes are written sequentially
 * across the 47 usable blocks (block 0 and every sector trailer skipped),
 * zero-padding the final block. The NFAR header is self-delimiting, so no
 * per-block framing is added.
 */

import { NFAR_MAGIC, NFAR_VERSION, TOTAL_OVERHEAD, NfarFormatError } from '../chunk.js';

export const BLOCK_SIZE = 16;

export const USABLE_BLOCK_INDEXES: readonly number[] = Object.freeze(
  Array.from({ length: 64 }, (_, b) => b).filter((b) => b !== 0 && b % 4 !== 3),
);

export const CARD_CAPACITY_BYTES = USABLE_BLOCK_INDEXES.length * BLOCK_SIZE; // 752
export const CARD_PAYLOAD_SIZE = CARD_CAPACITY_BYTES - TOTAL_OVERHEAD; // 720

export class CardCapacityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardCapacityError';
  }
}

export function chunkToBlocks(chunkBytes: Uint8Array): { block: number; data: Uint8Array }[] {
  if (chunkBytes.length > CARD_CAPACITY_BYTES) {
    throw new CardCapacityError(
      `Chunk is ${chunkBytes.length} bytes; a Mifare Classic 1K card holds ${CARD_CAPACITY_BYTES}`,
    );
  }
  const blockCount = Math.ceil(chunkBytes.length / BLOCK_SIZE);
  const out: { block: number; data: Uint8Array }[] = [];
  for (let i = 0; i < blockCount; i++) {
    const data = new Uint8Array(BLOCK_SIZE); // zero-filled -> pads the last block
    data.set(chunkBytes.subarray(i * BLOCK_SIZE, (i + 1) * BLOCK_SIZE));
    out.push({ block: USABLE_BLOCK_INDEXES[i]!, data });
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

export function nfarTotalLength(header: Uint8Array): number {
  if (!firstBlockIsNfar(header)) {
    throw new NfarFormatError('Not an NFAR card: magic or version mismatch');
  }
  if (header.length < 28) {
    throw new NfarFormatError(`Header too short: need 28 bytes, got ${header.length}`);
  }
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  const payloadSize = view.getUint16(26); // big-endian, per NFAR header layout
  return TOTAL_OVERHEAD + payloadSize;
}

export function assembleChunkFromBlocks(orderedBlockData: Uint8Array[], totalLength: number): Uint8Array {
  const flat = new Uint8Array(orderedBlockData.length * BLOCK_SIZE);
  orderedBlockData.forEach((b, i) => flat.set(b, i * BLOCK_SIZE));
  return flat.slice(0, totalLength);
}
