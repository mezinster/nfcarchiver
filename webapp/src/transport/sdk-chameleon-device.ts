/**
 * The ONLY file that imports chameleon-ultra.js. Wraps a live ChameleonUltra
 * instance behind the ChameleonDevice seam. Wire-up in the browser:
 *
 *   import { ChameleonUltra } from 'chameleon-ultra.js';
 *   import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
 *   const ultra = new ChameleonUltra();
 *   ultra.use(new WebbleAdapter());
 *   const device = new SdkChameleonDevice(ultra);
 *
 * The real ChameleonUltra satisfies ChameleonUltraSdk structurally; its Buffer
 * return values are Uint8Array subclasses.
 *
 * Verified against the installed chameleon-ultra.js@0.4.7 type declarations
 * (node_modules/chameleon-ultra.js/dist/_tsup-dts-rollup.d.ts):
 *  - Mf1KeyType.KEY_A = 96 (0x60) — matches MF1_KEY_A below.
 *  - cmdHf14aScan(): Promise<Array<{ uid: Buffer, atqa: Buffer, sak: Buffer, ats: Buffer }>>
 *    — the extra fields beyond `uid` are structurally harmless.
 *  - cmdMf1ReadBlock(known: { block, keyType, key }): Promise<Buffer> and
 *    cmdMf1WriteBlock(opts: { block, keyType, key, data }): Promise<void> take a
 *    single options object, NOT positional arguments — adjusted below
 *    accordingly (the original positional draft did not match the real SDK).
 */

import type { ChameleonDevice } from './chameleon-device.js';

/** Mifare Classic key type A. Mirrors the SDK's Mf1KeyType.KEY_A (0x60 / 96). */
export const MF1_KEY_A = 0x60;

/** Structural subset of ChameleonUltra used by this adapter. */
export interface ChameleonUltraSdk {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  cmdHf14aScan(): Promise<{ uid: Uint8Array }[]>;
  cmdMf1ReadBlock(known: { block: number; keyType: number; key: Uint8Array }): Promise<Uint8Array>;
  cmdMf1WriteBlock(opts: { block: number; keyType: number; key: Uint8Array; data: Uint8Array }): Promise<void>;
}

export class SdkChameleonDevice implements ChameleonDevice {
  constructor(private readonly sdk: ChameleonUltraSdk) {}

  isConnected(): boolean {
    return this.sdk.isConnected();
  }
  connect(): Promise<void> {
    return this.sdk.connect();
  }
  disconnect(): Promise<void> {
    return this.sdk.disconnect();
  }

  async scanTag(): Promise<Uint8Array | null> {
    const tags = await this.sdk.cmdHf14aScan();
    const first = tags[0];
    return first ? new Uint8Array(first.uid) : null;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    return new Uint8Array(await this.sdk.cmdMf1ReadBlock({ block, keyType: MF1_KEY_A, key }));
  }

  async writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> {
    await this.sdk.cmdMf1WriteBlock({ block, keyType: MF1_KEY_A, key, data });
  }
}
