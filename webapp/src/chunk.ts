/** NFAR v1 chunk codec. Mirrors lib/core/constants/nfar_format.dart and lib/core/models/chunk.dart. */

export const NFAR_MAGIC = new Uint8Array([0x4e, 0x46, 0x41, 0x52]); // "NFAR"
export const NFAR_VERSION = 0x01;
export const HEADER_SIZE = 28; // fields before payload
export const CRC_SIZE = 4;
export const TOTAL_OVERHEAD = HEADER_SIZE + CRC_SIZE; // 32
export const FLAG_COMPRESSED = 0x01;
export const FLAG_ENCRYPTED = 0x02;
export const MAX_CHUNKS = 65535;
export const MAX_PAYLOAD_SIZE = 65535;

export class NfarFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NfarFormatError';
  }
}

export interface Chunk {
  archiveId: Uint8Array; // 16 bytes
  totalChunks: number;
  chunkIndex: number;
  payload: Uint8Array;
  crc32: number;
  flags: number;
}

export function encodeChunk(chunk: Chunk): Uint8Array {
  if (chunk.archiveId.length !== 16) {
    throw new NfarFormatError(`Archive ID must be 16 bytes, got ${chunk.archiveId.length}`);
  }
  if (chunk.payload.length > MAX_PAYLOAD_SIZE) {
    throw new NfarFormatError(`Payload too large: ${chunk.payload.length}`);
  }
  const out = new Uint8Array(TOTAL_OVERHEAD + chunk.payload.length);
  const view = new DataView(out.buffer);
  out.set(NFAR_MAGIC, 0);
  out[4] = NFAR_VERSION;
  out[5] = chunk.flags;
  out.set(chunk.archiveId, 6);
  view.setUint16(22, chunk.totalChunks);
  view.setUint16(24, chunk.chunkIndex);
  view.setUint16(26, chunk.payload.length);
  out.set(chunk.payload, HEADER_SIZE);
  view.setUint32(HEADER_SIZE + chunk.payload.length, chunk.crc32);
  return out;
}

export function decodeChunk(data: Uint8Array): Chunk {
  if (data.length < TOTAL_OVERHEAD) {
    throw new NfarFormatError(
      `Data too short: expected at least ${TOTAL_OVERHEAD} bytes, got ${data.length}`,
    );
  }
  for (let i = 0; i < NFAR_MAGIC.length; i++) {
    if (data[i] !== NFAR_MAGIC[i]) {
      throw new NfarFormatError('Invalid magic bytes: not an NFAR chunk');
    }
  }
  const version = data[4]!;
  if (version !== NFAR_VERSION) {
    throw new NfarFormatError(`Unsupported version: ${version} (expected ${NFAR_VERSION})`);
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const flags = data[5]!;
  const archiveId = data.slice(6, 22);
  const totalChunks = view.getUint16(22);
  const chunkIndex = view.getUint16(24);
  const payloadSize = view.getUint16(26);
  const expectedTotal = HEADER_SIZE + payloadSize + CRC_SIZE;
  if (data.length < expectedTotal) {
    throw new NfarFormatError(
      `Data too short for payload: expected ${expectedTotal} bytes, got ${data.length}`,
    );
  }
  const payload = data.slice(HEADER_SIZE, HEADER_SIZE + payloadSize);
  const crc = view.getUint32(HEADER_SIZE + payloadSize);
  return { archiveId, totalChunks, chunkIndex, payload, crc32: crc, flags };
}
