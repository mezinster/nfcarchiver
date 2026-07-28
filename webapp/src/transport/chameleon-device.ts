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
  /** UID + SAK of a tag in the field, or null if none. SAK 0x08 = Mifare Classic 1K, 0x00 = NTAG/Type-2. */
  scanTag(): Promise<{ uid: Uint8Array; sak: number } | null>;
  /** Send a raw ISO 14443-A frame (with auto-select/CRC options) and return the response. */
  transceive14a(
    data: Uint8Array,
    opts?: { appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean },
  ): Promise<Uint8Array>;
  /** Read a 16-byte Mifare Classic block, authenticating with key A. */
  readBlock(block: number, key: Uint8Array): Promise<Uint8Array>;
  /** Write a 16-byte Mifare Classic block, authenticating with key A. */
  writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void>;
}

export const FACTORY_KEY_A = new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
