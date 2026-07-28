/**
 * Routes each presented tag to the right transport by its SAK: Mifare Classic 1K
 * (0x08) → ChameleonBleTransport, NTAG/Type-2 (0x00) → NtagTransport. The UI uses
 * this, so archive/restore work across both media transparently.
 */

import type { ChameleonDevice } from './chameleon-device.js';
import { ChameleonBleTransport } from './chameleon-ble.js';
import { NtagTransport } from './ntag-transport.js';
import { TagTimeoutError, UnsupportedTagError, type PresentedTag, type Transport } from './transport.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class AutoTransport implements Transport {
  readonly name = 'auto';
  private readonly classic: ChameleonBleTransport;
  private readonly ntag: NtagTransport;
  private active: Transport | null = null;
  private readonly pollMs: number;
  private readonly defaultTimeoutMs: number;

  constructor(private readonly device: ChameleonDevice, opts?: { pollMs?: number; defaultTimeoutMs?: number }) {
    this.classic = new ChameleonBleTransport(device, opts);
    this.ntag = new NtagTransport(device, opts);
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
        if (tag.sak === 0x08) this.active = this.classic;
        else if (tag.sak === 0x00) this.active = this.ntag;
        else throw new UnsupportedTagError(`Unsupported tag (SAK 0x${tag.sak.toString(16)})`);
        // The chosen delegate re-reads the present tag for capacity/type.
        return this.active.awaitTag({ ...opts, timeoutMs });
      }
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  private delegate(): Transport {
    if (this.active === null) throw new TagTimeoutError('No tag has been awaited yet');
    return this.active;
  }

  peekIsNfar(): Promise<boolean> { return this.delegate().peekIsNfar(); }
  readChunk(): Promise<Uint8Array> { return this.delegate().readChunk(); }
  writeChunk(bytes: Uint8Array): Promise<void> { return this.delegate().writeChunk(bytes); }
}
