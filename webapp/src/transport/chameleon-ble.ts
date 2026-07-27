import type { Transport } from './transport.js';

/**
 * Minimal surface of the chameleon-ultra.js SDK (MIT) this transport needs.
 * Intended wiring in the browser:
 *   const ultra = new ChameleonUltra()
 *   ultra.use(new WebbleAdapter())   // or WebserialAdapter for USB
 *   new ChameleonBleTransport(ultra)
 * The real SDK instance satisfies this interface structurally.
 */
export interface ChameleonUltraLike {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;
}

export class NotImplementedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotImplementedError';
  }
}

/**
 * Transport stub for the Chameleon Ultra over Web Bluetooth.
 * Chunk <-> Mifare Classic block mapping is out of scope for this prototype
 * (see the design spec); read/write throw until that layout is designed.
 */
export class ChameleonBleTransport implements Transport {
  readonly name = 'chameleon-ble';

  constructor(private readonly device: ChameleonUltraLike) {}

  async connect(): Promise<void> {
    if (!this.device.isConnected()) await this.device.connect();
  }

  async disconnect(): Promise<void> {
    if (this.device.isConnected()) await this.device.disconnect();
  }

  async detectCapacity(): Promise<number> {
    // Mifare Classic 1K: 64 blocks x 16 B, minus 16 sector trailers and
    // the manufacturer block -> 47 usable blocks = 752 bytes.
    return 752;
  }

  async writeChunk(_bytes: Uint8Array): Promise<void> {
    throw new NotImplementedError('Mifare Classic block mapping is not implemented in this prototype');
  }

  async readChunk(): Promise<Uint8Array> {
    throw new NotImplementedError('Mifare Classic block mapping is not implemented in this prototype');
  }
}
