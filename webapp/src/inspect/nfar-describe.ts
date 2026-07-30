/**
 * Tolerant NFAR header description for the card inspector.
 *
 * `decodeChunk()` throws on the first problem it meets. That is correct for the
 * restore path, where a bad chunk must not proceed, and useless here: in an
 * inspector the failure IS the information ("magic mismatch: got 00 00 00 00").
 * This reports instead of raising.
 *
 * It also accepts a PARTIAL buffer, so the dialog can render the header from the
 * first two data blocks and fill in CRC status later, once the dump reaches the
 * tail. Unknown CRC status is `null`, never `false` — `false` would read as
 * corruption.
 */
import {
  NFAR_MAGIC, NFAR_VERSION, HEADER_SIZE, TOTAL_OVERHEAD,
  FLAG_COMPRESSED, FLAG_ENCRYPTED,
} from '../chunk.js';
import { crc32 } from '../crc32.js';
import { formatArchiveId } from '../archive-id.js';
import { CARD_CAPACITY_BYTES } from '../mifare/card-layout.js';

export interface NfarAbsent {
  present: false;
  reason: string;
}

export interface NfarPresent {
  present: true;
  version: number;
  flags: number;
  compressed: boolean;
  encrypted: boolean;
  archiveId: string;
  chunkIndex: number;
  totalChunks: number;
  payloadSize: number;
  /** 32 + payloadSize — the whole chunk's on-card length. */
  totalLength: number;
  /** null until the dump has read as far as the CRC tail. */
  crcStored: number | null;
  crcComputed: number | null;
  crcValid: boolean | null;
  /** Non-fatal oddities worth surfacing; the header is still described. */
  warnings: string[];
}

export type NfarDescription = NfarAbsent | NfarPresent;

const spaced = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

export function describeNfar(data: Uint8Array): NfarDescription {
  const minToJudge = NFAR_MAGIC.length + 1;
  if (data.length < minToJudge) {
    return { present: false, reason: `only ${data.length} bytes read; need at least ${minToJudge} to identify a chunk` };
  }
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (data[i] !== NFAR_MAGIC[i]) {
      return {
        present: false,
        reason: `magic mismatch: got ${spaced(data.subarray(0, NFAR_MAGIC.length))}, expected 4E 46 41 52 ("NFAR")`,
      };
    }
  }
  const version = data[4]!;
  if (version !== NFAR_VERSION) {
    return { present: false, reason: `unsupported version ${version} (expected ${NFAR_VERSION})` };
  }
  if (data.length < HEADER_SIZE) {
    return { present: false, reason: `header incomplete: ${data.length} of ${HEADER_SIZE} bytes read` };
  }

  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const flags = data[5]!;
  const totalChunks = view.getUint16(22);
  const chunkIndex = view.getUint16(24);
  const payloadSize = view.getUint16(26);
  const totalLength = TOTAL_OVERHEAD + payloadSize;

  const warnings: string[] = [];
  if (totalLength > CARD_CAPACITY_BYTES) {
    warnings.push(`declared length ${totalLength} B exceeds Mifare Classic 1K capacity ${CARD_CAPACITY_BYTES} B`);
  }
  if ((flags & ~(FLAG_COMPRESSED | FLAG_ENCRYPTED)) !== 0) {
    warnings.push(`unknown flag bits set: 0x${flags.toString(16).padStart(2, '0')}`);
  }
  if (totalChunks > 0 && chunkIndex >= totalChunks) {
    warnings.push(`chunk index ${chunkIndex} is out of range for ${totalChunks} chunk(s)`);
  }

  let crcStored: number | null = null;
  let crcComputed: number | null = null;
  if (data.length >= totalLength) {
    crcStored = view.getUint32(HEADER_SIZE + payloadSize);
    crcComputed = crc32(data.subarray(HEADER_SIZE, HEADER_SIZE + payloadSize));
  }

  return {
    present: true,
    version,
    flags,
    compressed: (flags & FLAG_COMPRESSED) !== 0,
    encrypted: (flags & FLAG_ENCRYPTED) !== 0,
    archiveId: formatArchiveId(data.subarray(6, 22)),
    chunkIndex,
    totalChunks,
    payloadSize,
    totalLength,
    crcStored,
    crcComputed,
    crcValid: crcStored === null ? null : crcStored === crcComputed,
    warnings,
  };
}
