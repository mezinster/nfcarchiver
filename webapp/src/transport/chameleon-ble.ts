/**
 * Real Transport over a Chameleon Ultra reading/writing physical Mifare Classic
 * 1K and 4K cards (4K writes beyond 752 B only while `allow4k()` is true). Talks only to the ChameleonDevice seam, so it is fully testable
 * against FakeChameleon; the actual SDK is wired in via SdkChameleonDevice.
 */

import { NfarFormatError } from '../chunk.js';
import { TOTAL_OVERHEAD } from '../chunk.js';
import {
  BLOCK_SIZE, CARD_CAPACITY_BYTES, capacityBytes, firstBlockOfSector, sectorOf, usableBlocks, writableCapacity,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks, type CardSize,
} from '../mifare/card-layout.js';
import { classifySak, cardSizeFor } from '../mifare/sak.js';
import { FACTORY_KEY_A, type ChameleonDevice } from './chameleon-device.js';
import { CardReadError, TagTimeoutError, WriteVerifyError, type PresentedTag, type Transport } from './transport.js';

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class ChameleonBleTransport implements Transport {
  readonly name = 'chameleon-ble';
  private readonly pollMs: number;
  private readonly defaultTimeoutMs: number;
  private readonly allow4k: () => boolean;
  /** Geometry of the card from the last awaitTag. Reads trust it; writes are gated by allow4k. */
  private size: CardSize = '1k';

  constructor(
    private readonly device: ChameleonDevice,
    opts?: { pollMs?: number; defaultTimeoutMs?: number; allow4k?: () => boolean },
  ) {
    this.allow4k = opts?.allow4k ?? (() => false);
    this.pollMs = opts?.pollMs ?? 300;
    this.defaultTimeoutMs = opts?.defaultTimeoutMs ?? 20000;
  }

  async connect(): Promise<void> {
    if (!this.device.isConnected()) await this.device.connect();
  }

  async disconnect(): Promise<void> {
    if (this.device.isConnected()) await this.device.disconnect();
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const timeoutMs = opts?.timeoutMs ?? this.defaultTimeoutMs;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const tag = await this.device.scanTag();
      if (tag !== null) {
        this.size = cardSizeFor(classifySak(tag.sak)) ?? '1k';
        return {
          uid: tag.uid,
          capacityBytes: capacityBytes(this.size),
          maxChunkPayload: writableCapacity(this.size, this.allow4k()) - TOTAL_OVERHEAD,
        };
      }
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  /** Every read goes through here: a short response is a marginal RF read, not
   *  card content, so it is rejected as transient instead of being treated as
   *  (zero-padded) data — which would read as "this card holds no NFAR chunk". */
  private async readBlockStrict(block: number): Promise<Uint8Array> {
    const data = await this.device.readBlock(block, FACTORY_KEY_A);
    if (data.length !== BLOCK_SIZE) {
      throw new CardReadError(`Short read on block ${block}: got ${data.length} of ${BLOCK_SIZE} bytes`);
    }
    return data;
  }

  private readUsable(i: number): Promise<Uint8Array> {
    return this.readBlockStrict(usableBlocks(this.size)[i]!);
  }

  async peekIsNfar(): Promise<boolean> {
    const block1 = await this.readUsable(0);
    return firstBlockIsNfar(block1);
  }

  async readChunk(): Promise<Uint8Array> {
    // First two usable blocks (32 bytes) cover the full NFAR header incl. payloadSize.
    const first = await this.readUsable(0);
    if (!firstBlockIsNfar(first)) throw new NfarFormatError('Current card contains no NFAR chunk');
    const second = await this.readUsable(1);
    const header = new Uint8Array(2 * BLOCK_SIZE);
    header.set(first, 0);
    header.set(second, BLOCK_SIZE);
    const total = nfarTotalLength(header, this.size);
    const blockCount = Math.ceil(total / BLOCK_SIZE);
    const blocks: Uint8Array[] = [first, second];
    for (let i = 2; i < blockCount; i++) blocks.push(await this.readUsable(i));
    return assembleChunkFromBlocks(blocks.slice(0, blockCount), total);
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    // Writes use the 4K geometry only while the switch is on; otherwise a 4K card
    // is treated as 1K and anything over 752 B throws CardCapacityError.
    const writeSize: CardSize = this.size === '4k' && this.allow4k() ? '4k' : '1k';
    const blocks = chunkToBlocks(bytes, writeSize);
    if (bytes.length > CARD_CAPACITY_BYTES) {
      // Beyond sector 15 the sectors may carry non-factory keys; find out before
      // the first write so a refused sector cannot leave half a chunk behind.
      const probed = new Set<number>();
      for (const { block } of blocks) {
        const sector = sectorOf(block);
        if (probed.has(sector)) continue;
        probed.add(sector);
        await this.device.readBlock(sector === 0 ? 1 : firstBlockOfSector(sector), FACTORY_KEY_A);
      }
    }
    for (const { block, data } of blocks) await this.device.writeBlock(block, FACTORY_KEY_A, data);
    for (const { block, data } of blocks) {
      const readBack = await this.readBlockStrict(block);
      if (!bytesEqual(readBack, data)) {
        throw new WriteVerifyError(`Verification failed on block ${block}: read-back does not match`);
      }
    }
  }
}
