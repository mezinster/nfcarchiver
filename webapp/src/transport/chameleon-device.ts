/**
 * Narrow structural seam over the Chameleon Ultra SDK. ChameleonBleTransport
 * depends only on this. The real SDK is wrapped by SdkChameleonDevice
 * (Task 5, the only file importing chameleon-ultra.js); FakeChameleon
 * implements it for tests (Task 3).
 */
export interface ChameleonDevice {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** UID of a tag currently in the field, or null if none. */
  scanTag(): Promise<Uint8Array | null>;
  /** Read a 16-byte block, authenticating with key A. */
  readBlock(block: number, key: Uint8Array): Promise<Uint8Array>;
  /** Write a 16-byte block, authenticating with key A. */
  writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void>;
}

export const FACTORY_KEY_A = new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
