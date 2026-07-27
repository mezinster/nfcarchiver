/**
 * DOM-free state machines for the archive and restore flows. The UI glue
 * (main.ts) drives these and renders their progress; they touch only a
 * Transport, so they are unit-tested against MockTransport.
 */

import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { NfarFormatError } from '../src/chunk.js';
import type { Transport } from '../src/transport/transport.js';

export interface ArchiveRequest {
  data: Uint8Array;
  compress: boolean;
  password?: string;
}

export interface ArchiveProgress {
  total: number;
  written: number;
  awaiting: number | null;
}

export class OverwriteRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OverwriteRequiredError';
  }
}

export class PasswordRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PasswordRequiredError';
  }
}

export class WrongArchiveError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WrongArchiveError';
  }
}

function uidHex(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

export class ArchiveController {
  private chunks: Chunk[] = [];
  private written = 0;
  private readonly writtenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async prepare(req: ArchiveRequest): Promise<number> {
    this.chunks = await archive(req.data, {
      payloadSize: CARD_PAYLOAD_SIZE,
      compress: req.compress,
      password: req.password,
    });
    this.written = 0;
    this.writtenUids.clear();
    return this.chunks.length;
  }

  private progress(awaiting: number | null): ArchiveProgress {
    return { total: this.chunks.length, written: this.written, awaiting };
  }

  /**
   * Present the next card and write the next unwritten chunk to it.
   * A card whose UID was already written is skipped (returns not-done, no write).
   * If the presented card already holds NFAR data and confirmOverwrite is not
   * true, throws OverwriteRequiredError without writing.
   */
  async writeNextCard(signal?: AbortSignal, confirmOverwrite = false): Promise<{ done: boolean; progress: ArchiveProgress }> {
    if (this.written >= this.chunks.length) return { done: true, progress: this.progress(null) };
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (this.writtenUids.has(key)) {
      return { done: false, progress: this.progress(this.written) };
    }
    if (!confirmOverwrite && (await this.transport.peekIsNfar())) {
      throw new OverwriteRequiredError('This card already holds NFAR data; confirm to overwrite');
    }
    await this.transport.writeChunk(encodeChunk(this.chunks[this.written]!));
    this.writtenUids.add(key);
    this.written += 1;
    const done = this.written >= this.chunks.length;
    return { done, progress: this.progress(done ? null : this.written) };
  }
}

export class RestoreController {
  private readonly collected = new Map<number, Chunk>();
  private readonly seenUids = new Set<string>();
  private total: number | null = null;
  private encrypted = false;
  private archiveId: Uint8Array | null = null;

  constructor(private readonly transport: Transport) {}

  async scanNextCard(signal?: AbortSignal): Promise<{ done: boolean; collected: number; total: number | null }> {
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    if (!this.seenUids.has(key)) {
      const chunk = decodeChunk(await this.transport.readChunk());
      if (this.archiveId !== null && !bytesEqual(chunk.archiveId, this.archiveId)) {
        throw new WrongArchiveError('This card belongs to a different archive');
      }
      this.seenUids.add(key);
      if (!this.collected.has(chunk.chunkIndex)) {
        this.collected.set(chunk.chunkIndex, chunk);
        this.total = chunk.totalChunks;
        this.encrypted = (chunk.flags & FLAG_ENCRYPTED) !== 0;
        if (this.archiveId === null) this.archiveId = chunk.archiveId;
      }
    }
    const done = this.total !== null && this.collected.size >= this.total;
    return { done, collected: this.collected.size, total: this.total };
  }

  async finish(password?: string): Promise<Uint8Array> {
    if (this.encrypted && password === undefined) {
      throw new PasswordRequiredError('This archive is encrypted; a password is required');
    }
    const chunks = [...this.collected.values()];
    return restore(chunks, password);
  }
}

// Re-export so main.ts and tests can surface a clean not-an-NFAR-card message.
export { NfarFormatError };
