/**
 * DOM-free state machines for the archive and restore flows. They touch only a
 * Transport and are unit-tested against MockTransport. The filename wrapper
 * (matching the Flutter app) is applied here, above the unchanged core.
 */

import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { NfarFormatError } from '../src/chunk.js';
import { NdefFormatError } from '../src/nfc/ndef.js';
import { wrapWithFilename, unwrapFilename } from '../src/filename.js';
import { formatArchiveId } from '../src/archive-id.js';
import type { Transport } from '../src/transport/transport.js';

export interface ArchiveRequest {
  data: Uint8Array;
  fileName: string;
  compress: boolean;
  password?: string;
  payloadSize: number;
}

export interface ArchiveProgress {
  total: number;
  written: number;
  awaiting: number | null;
}

export interface DetectedArchive {
  archiveId: string;
  shortId: string;
  totalChunks: number;
  received: number;
  isEncrypted: boolean;
  isCompressed: boolean;
  complete: boolean;
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

function uidHex(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

export class ArchiveController {
  private chunks: Chunk[] = [];
  private written = 0;
  private readonly writtenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async prepare(req: ArchiveRequest): Promise<number> {
    const wrapped = wrapWithFilename(req.data, req.fileName);
    this.chunks = await archive(wrapped, {
      payloadSize: req.payloadSize,
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

interface ArchiveGroup {
  archiveId: Uint8Array;
  totalChunks: number;
  flags: number;
  chunks: Map<number, Chunk>;
}

export class RestoreController {
  private readonly groups = new Map<string, ArchiveGroup>(); // keyed by formatted UUID
  private readonly seenUids = new Set<string>();

  constructor(private readonly transport: Transport) {}

  async scanNextCard(signal?: AbortSignal): Promise<DetectedArchive[]> {
    const tag = await this.transport.awaitTag({ signal });
    const uid = uidHex(tag.uid);
    if (!this.seenUids.has(uid)) {
      let chunk: Chunk;
      try {
        chunk = decodeChunk(await this.transport.readChunk());
      } catch (e) {
        // A blank/foreign/undecodable card in the pile shouldn't end the scan:
        // remember its UID (so it isn't re-read on a re-tap) and skip it.
        if (e instanceof NfarFormatError || e instanceof NdefFormatError) {
          this.seenUids.add(uid);
          return this.detectedArchives();
        }
        throw e; // a transient I/O failure — let the caller decide
      }
      const id = formatArchiveId(chunk.archiveId);
      let group = this.groups.get(id);
      if (group === undefined) {
        group = { archiveId: chunk.archiveId, totalChunks: chunk.totalChunks, flags: chunk.flags, chunks: new Map() };
        this.groups.set(id, group);
      }
      group.chunks.set(chunk.chunkIndex, chunk);
      this.seenUids.add(uid);
    }
    return this.detectedArchives();
  }

  detectedArchives(): DetectedArchive[] {
    return [...this.groups.entries()].map(([id, g]) => ({
      archiveId: id,
      shortId: id.slice(0, 8),
      totalChunks: g.totalChunks,
      received: g.chunks.size,
      isEncrypted: (g.flags & FLAG_ENCRYPTED) !== 0,
      isCompressed: (g.flags & FLAG_COMPRESSED) !== 0,
      complete: g.chunks.size >= g.totalChunks,
    }));
  }

  async restore(archiveId: string, password?: string): Promise<{ data: Uint8Array; fileName: string | null }> {
    const group = this.groups.get(archiveId);
    if (group === undefined) throw new Error(`No detected archive ${archiveId}`);
    if ((group.flags & FLAG_ENCRYPTED) !== 0 && password === undefined) {
      throw new PasswordRequiredError('This archive is encrypted; a password is required');
    }
    const raw = await restore([...group.chunks.values()], password);
    return unwrapFilename(raw);
  }
}

// Re-export so main.ts and tests can surface a clean not-an-NFAR-card message.
export { NfarFormatError };
