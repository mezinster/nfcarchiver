import { NfarFormatError } from '../chunk.js';
import { CARD_CAPACITY_BYTES, CardCapacityError, firstBlockIsNfar } from '../mifare/card-layout.js';
import { TagTimeoutError, type PresentedTag, type Transport } from './transport.js';

function toHexKey(uid: Uint8Array): string {
  return Array.from(uid, (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * In-memory Transport double. Tests script a sequence of taps with enqueueTag;
 * each awaitTag presents the next one. Card contents are keyed by UID, so
 * re-enqueuing the same UID presents the same (already-written) card.
 */
export class MockTransport implements Transport {
  readonly name = 'mock';
  private readonly queue: string[] = [];
  private readonly cards = new Map<string, Uint8Array>();
  private active: string | null = null;

  /** Present `uid` on the next awaitTag; optionally pre-load its stored chunk bytes. */
  enqueueTag(uid: Uint8Array, chunkBytes?: Uint8Array): void {
    const key = toHexKey(uid);
    this.queue.push(key);
    if (chunkBytes) this.cards.set(key, chunkBytes.slice());
  }

  async connect(): Promise<void> {}
  async disconnect(): Promise<void> {}

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    const next = this.queue.shift();
    if (next === undefined) {
      throw new TagTimeoutError(`No tag presented within ${opts?.timeoutMs ?? 0}ms`);
    }
    this.active = next;
    return { uid: Uint8Array.from(next.match(/../g)!.map((h) => parseInt(h, 16))), capacityBytes: CARD_CAPACITY_BYTES };
  }

  private activeBytes(): Uint8Array | undefined {
    return this.active === null ? undefined : this.cards.get(this.active);
  }

  async peekIsNfar(): Promise<boolean> {
    const b = this.activeBytes();
    return b !== undefined && b.length >= 16 && firstBlockIsNfar(b.subarray(0, 16));
  }

  async readChunk(): Promise<Uint8Array> {
    const b = this.activeBytes();
    if (b === undefined || !firstBlockIsNfar(b.subarray(0, 16))) {
      throw new NfarFormatError('Current card contains no NFAR chunk');
    }
    return b.slice();
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    if (this.active === null) throw new TagTimeoutError('No active tag to write');
    if (bytes.length > CARD_CAPACITY_BYTES) {
      throw new CardCapacityError(`Chunk ${bytes.length} B exceeds card capacity ${CARD_CAPACITY_BYTES} B`);
    }
    this.cards.set(this.active, bytes.slice());
  }
}
