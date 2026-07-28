/**
 * Archive: data -> (gzip if it shrinks) -> (encrypt if password) -> chunks.
 * Restore: chunks -> assemble -> (decrypt) -> (gunzip) -> data.
 * Mirrors the flag semantics of the Flutter ArchiveNotifier flow.
 */

import { FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from './chunk.js';
import { assembleChunks, createChunks } from './chunker.js';
import { decrypt, DecryptionError, encrypt } from './crypto.js';
import { gzipCompress, gzipDecompress } from './gzip.js';

export interface ArchiveOptions {
  payloadSize: number;
  compress?: boolean;
  password?: string;
  archiveId?: Uint8Array;
}

export async function archive(data: Uint8Array, options: ArchiveOptions): Promise<Chunk[]> {
  let payload = data;
  let flags = 0;
  if (options.compress) {
    const compressed = await gzipCompress(data);
    if (compressed.length < data.length) {
      payload = compressed;
      flags |= FLAG_COMPRESSED;
    }
  }
  if (options.password !== undefined) {
    payload = await encrypt(payload, options.password);
    flags |= FLAG_ENCRYPTED;
  }
  return createChunks(payload, options.payloadSize, flags, options.archiveId);
}

export async function restoreFromPayload(
  payload: Uint8Array,
  opts: { isEncrypted: boolean; isCompressed: boolean },
  password?: string,
): Promise<Uint8Array> {
  let data = payload;
  if (opts.isEncrypted) {
    if (password === undefined) {
      throw new DecryptionError('Archive is encrypted; password required');
    }
    data = await decrypt(data, password);
  }
  if (opts.isCompressed) {
    data = await gzipDecompress(data);
  }
  return data;
}

export async function restore(chunks: Chunk[], password?: string): Promise<Uint8Array> {
  const flags = chunks[0]!.flags;
  return restoreFromPayload(
    assembleChunks(chunks),
    { isEncrypted: (flags & FLAG_ENCRYPTED) !== 0, isCompressed: (flags & FLAG_COMPRESSED) !== 0 },
    password,
  );
}
