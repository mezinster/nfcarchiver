/**
 * A Transport moves serialized NFAR chunk bytes to/from physical media:
 * NFC tags via the phone (Web NFC), or Mifare Classic cards via a
 * Chameleon Ultra over Web Bluetooth / Web Serial.
 */
export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Usable bytes on the currently presented tag/card. */
  detectCapacity(): Promise<number>;
  writeChunk(bytes: Uint8Array): Promise<void>;
  readChunk(): Promise<Uint8Array>;
}
