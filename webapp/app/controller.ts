/**
 * DOM-free state machines for the archive and restore flows. They touch only a
 * Transport and are unit-tested against MockTransport. The filename wrapper
 * (matching the Flutter app) is applied here, above the unchanged core.
 */

import { archive, restore } from '../src/pipeline.js';
import { decodeChunk, encodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { NfarFormatError } from '../src/chunk.js';
import { assembleChunks, createChunks } from '../src/chunker.js';
import { NdefFormatError } from '../src/nfc/ndef.js';
import { wrapWithFilename, unwrapFilename } from '../src/filename.js';
import { formatArchiveId } from '../src/archive-id.js';
import { log } from '../src/log/logger.js';
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

/**
 * Boundary events inside a single writeNextCard call, reported as they happen.
 *
 * A card operation is one long await from the caller's point of view — tag
 * detection, the NFAR peek, then (on a Mifare Classic 1K) 47 block writes and
 * 47 verify reads, 15-25 s of BLE round trips. Without these events a stall
 * anywhere in that span is indistinguishable from "the user has not tapped
 * yet": the status line still shows the previous card's prompt and the log is
 * empty. The core stays free of the logger — the caller decides what to do
 * with these.
 */
export type ArchiveWriteEvent =
  | { phase: 'tag'; uid: string; maxChunkPayload: number }
  | { phase: 'already-written'; uid: string }
  | { phase: 'peeked'; uid: string; isNfar: boolean }
  | { phase: 'writing'; uid: string; chunkIndex: number; bytes: number }
  | { phase: 'written'; uid: string; chunkIndex: number };

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

export class RechunkTooLateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RechunkTooLateError';
  }
}

function uidHex(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

export class ArchiveController {
  private chunks: Chunk[] = [];
  private written = 0;
  private payloadSize = 0;
  private readonly writtenUids = new Set<string>();
  private transport: Transport;

  constructor(transport: Transport) { this.transport = transport; }

  /** Swap the transport used by subsequent writeNextCard calls. Session state
   *  (chunks, written count, written UIDs, payload size) is preserved — used to
   *  resume a paused write on a freshly-built transport after a reconnect. */
  setTransport(t: Transport): void { this.transport = t; }

  async prepare(req: ArchiveRequest): Promise<number> {
    const wrapped = wrapWithFilename(req.data, req.fileName);
    this.chunks = await archive(wrapped, {
      payloadSize: req.payloadSize,
      compress: req.compress,
      password: req.password,
    });
    this.payloadSize = req.payloadSize;
    this.written = 0;
    this.writtenUids.clear();
    return this.chunks.length;
  }

  /** Re-split the already-processed payload to a new per-card size, preserving the
   *  archiveId (no re-encrypt). Only valid before any card is written. */
  rechunkForCapacity(newPayloadSize: number): number {
    if (this.written > 0) throw new RechunkTooLateError('Cannot re-chunk after writing has started');
    const payload = assembleChunks(this.chunks);
    const { flags, archiveId } = this.chunks[0]!;
    this.chunks = createChunks(payload, newPayloadSize, flags, archiveId);
    this.payloadSize = newPayloadSize;
    return this.chunks.length;
  }

  private progress(awaiting: number | null): ArchiveProgress {
    return { total: this.chunks.length, written: this.written, awaiting };
  }

  async writeNextCard(
    signal?: AbortSignal,
    confirmOverwrite = false,
    onEvent?: (e: ArchiveWriteEvent) => void,
  ): Promise<{ done: boolean; progress: ArchiveProgress; rechunkedTo?: { total: number; payloadSize: number }; skipped?: 'already-written' }> {
    if (this.written >= this.chunks.length) return { done: true, progress: this.progress(null) };
    const tag = await this.transport.awaitTag({ signal });
    const key = uidHex(tag.uid);
    onEvent?.({ phase: 'tag', uid: key, maxChunkPayload: tag.maxChunkPayload });
    if (this.writtenUids.has(key)) {
      // No progress is possible from this card. Reported rather than returned
      // as a bare no-op: the caller must be able to say so and to pace itself,
      // or a card left sitting on the reader becomes an unthrottled, silent
      // poll loop that looks exactly like a hang.
      onEvent?.({ phase: 'already-written', uid: key });
      return { done: false, progress: this.progress(this.written), skipped: 'already-written' };
    }
    let rechunkedTo: { total: number; payloadSize: number } | undefined;
    if (this.written === 0 && tag.maxChunkPayload !== this.payloadSize) {
      const total = this.rechunkForCapacity(tag.maxChunkPayload);
      rechunkedTo = { total, payloadSize: tag.maxChunkPayload };
    }
    if (!confirmOverwrite) {
      const isNfar = await this.transport.peekIsNfar();
      onEvent?.({ phase: 'peeked', uid: key, isNfar });
      if (isNfar) throw new OverwriteRequiredError('This card already holds NFAR data; confirm to overwrite');
    }
    const bytes = encodeChunk(this.chunks[this.written]!);
    onEvent?.({ phase: 'writing', uid: key, chunkIndex: this.written, bytes: bytes.length });
    await this.transport.writeChunk(bytes);
    onEvent?.({ phase: 'written', uid: key, chunkIndex: this.written });
    this.writtenUids.add(key);
    this.written += 1;
    const done = this.written >= this.chunks.length;
    return { done, progress: this.progress(done ? null : this.written), ...(rechunkedTo ? { rechunkedTo } : {}) };
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
        // remember its UID (so it isn't re-read on a re-tap) and skip it. This
        // verdict is sticky, so only a healthy full read may produce it — the
        // transports reject a short read as CardReadError, which falls through
        // to the caller and leaves the UID re-tappable.
        if (e instanceof NfarFormatError || e instanceof NdefFormatError) {
          this.seenUids.add(uid);
          log.debug('scan', 'Card skipped — holds no NFAR data', { uid, error: String(e) });
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

  /** Assembled chunk payload for a detected group — the pre-decrypt bytes
   *  (ciphertext when the archive is encrypted). Used to persist a Files entry. */
  assembledPayload(archiveId: string): Uint8Array {
    const group = this.groups.get(archiveId);
    if (group === undefined) throw new Error(`No detected archive ${archiveId}`);
    return assembleChunks([...group.chunks.values()]);
  }
}

// Re-export so main.ts and tests can surface a clean not-an-NFAR-card message.
export { NfarFormatError };
