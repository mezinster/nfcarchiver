/**
 * Real Transport over a Chameleon Ultra reading/writing physical Mifare Classic
 * 1K cards. Talks only to the ChameleonDevice seam, so it is fully testable
 * against FakeChameleon; the actual SDK is wired in via SdkChameleonDevice.
 */

import { NfarFormatError } from '../chunk.js';
import {
  BLOCK_SIZE, CARD_CAPACITY_BYTES, USABLE_BLOCK_INDEXES,
  chunkToBlocks, firstBlockIsNfar, nfarTotalLength, assembleChunkFromBlocks,
} from '../mifare/card-layout.js';
import { FACTORY_KEY_A, type ChameleonDevice } from './chameleon-device.js';
import { TagTimeoutError, WriteVerifyError, type PresentedTag, type Transport } from './transport.js';

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

  constructor(private readonly device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number }) {
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
      const uid = await this.device.scanTag();
      if (uid !== null) return { uid, capacityBytes: CARD_CAPACITY_BYTES };
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  private readUsable(i: number): Promise<Uint8Array> {
    return this.device.readBlock(USABLE_BLOCK_INDEXES[i]!, FACTORY_KEY_A);
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
    const total = nfarTotalLength(header);
    const blockCount = Math.ceil(total / BLOCK_SIZE);
    const blocks: Uint8Array[] = [first, second];
    for (let i = 2; i < blockCount; i++) blocks.push(await this.readUsable(i));
    return assembleChunkFromBlocks(blocks.slice(0, blockCount), total);
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const blocks = chunkToBlocks(bytes); // throws CardCapacityError if > 752
    for (const { block, data } of blocks) await this.device.writeBlock(block, FACTORY_KEY_A, data);
    for (const { block, data } of blocks) {
      const readBack = await this.device.readBlock(block, FACTORY_KEY_A);
      if (!bytesEqual(readBack, data)) {
        throw new WriteVerifyError(`Verification failed on block ${block}: read-back does not match`);
      }
    }
  }
}
