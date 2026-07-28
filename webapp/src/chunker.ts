/** Splitting and reassembly, mirroring lib/core/services/chunker_service.dart. */

import { crc32 } from './crc32.js';
import { MAX_CHUNKS, MAX_PAYLOAD_SIZE, type Chunk } from './chunk.js';

export class NfarAssemblyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NfarAssemblyError';
  }
}

export function generateArchiveId(): Uint8Array {
  const id = crypto.getRandomValues(new Uint8Array(16));
  id[6] = (id[6]! & 0x0f) | 0x40; // UUID version 4
  id[8] = (id[8]! & 0x3f) | 0x80; // RFC 4122 variant
  return id;
}

export function createChunks(
  data: Uint8Array,
  payloadSize: number,
  flags = 0,
  archiveId?: Uint8Array,
): Chunk[] {
  if (payloadSize <= 0) throw new RangeError('Payload size must be positive');
  if (payloadSize > MAX_PAYLOAD_SIZE) {
    throw new RangeError(`Payload size too large: ${payloadSize} > ${MAX_PAYLOAD_SIZE}`);
  }
  const id = archiveId ?? generateArchiveId();
  const totalChunks = Math.ceil(data.length / payloadSize);
  if (totalChunks > MAX_CHUNKS) {
    throw new RangeError(`Data too large: would need ${totalChunks} chunks, maximum is ${MAX_CHUNKS}`);
  }
  const chunks: Chunk[] = [];
  for (let i = 0; i < totalChunks; i++) {
    const payload = data.subarray(i * payloadSize, Math.min((i + 1) * payloadSize, data.length));
    chunks.push({ archiveId: id, totalChunks, chunkIndex: i, payload, crc32: crc32(payload), flags });
  }
  return chunks;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export function assembleChunks(chunks: Chunk[]): Uint8Array {
  if (chunks.length === 0) throw new NfarAssemblyError('No chunks provided');
  const sorted = [...chunks].sort((a, b) => a.chunkIndex - b.chunkIndex);
  const { archiveId, totalChunks } = sorted[0]!;
  for (const c of sorted) {
    if (!bytesEqual(c.archiveId, archiveId)) {
      throw new NfarAssemblyError('Chunks are from different archives');
    }
    if (c.totalChunks !== totalChunks) {
      throw new NfarAssemblyError(`Inconsistent total chunks: ${totalChunks} vs ${c.totalChunks}`);
    }
  }
  const indices = new Set(sorted.map((c) => c.chunkIndex));
  const missing: number[] = [];
  for (let i = 0; i < totalChunks; i++) if (!indices.has(i)) missing.push(i);
  if (missing.length > 0) throw new NfarAssemblyError(`Missing chunks: ${missing.join(', ')}`);
  if (sorted.length !== totalChunks) {
    throw new NfarAssemblyError(`Duplicate chunks detected: have ${sorted.length}, expected ${totalChunks}`);
  }
  for (const c of sorted) {
    if (crc32(c.payload) !== c.crc32) {
      throw new NfarAssemblyError(`CRC mismatch for chunk ${c.chunkIndex}: data may be corrupted`);
    }
  }
  let totalSize = 0;
  for (const c of sorted) totalSize += c.payload.length;
  const out = new Uint8Array(totalSize);
  let offset = 0;
  for (const c of sorted) {
    out.set(c.payload, offset);
    offset += c.payload.length;
  }
  return out;
}
