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
 *
 * Verified against the installed chameleon-ultra.js@0.4.7 runtime (dist/index.mjs):
 *  - The SDK's internal `Buffer.isBuffer()` check rejects plain Uint8Array —
 *    keys/data passed to cmdMf1ReadBlock/cmdMf1WriteBlock must be wrapped with
 *    the SDK's own `Buffer.from(...)` (re-exported from the package's main
 *    entry) before being handed to the SDK.
 *  - cmdHf14aScan() throws (does not return []) when no tag is present, with
 *    `.status === HF_TAG_NOT_FOUND` (1) on the thrown error.
 *  - Mifare auth failures (wrong/non-factory key) surface as a thrown error
 *    with `.status === MF_ERR_AUTH` (6) from cmdMf1ReadBlock/cmdMf1WriteBlock.
 */

import { Buffer } from 'chameleon-ultra.js';
import type { ChameleonDevice } from './chameleon-device.js';
import { CardAuthError } from './transport.js';

/** Mifare Classic key type A. Mirrors the SDK's Mf1KeyType.KEY_A (0x60 / 96). */
export const MF1_KEY_A = 0x60;

/** SDK status code for "no tag in the field" (cmdHf14aScan throws this). */
const HF_TAG_NOT_FOUND = 1;

/** SDK status code for a Mifare auth failure (wrong/non-factory key). */
const MF_ERR_AUTH = 6;

/** Structural subset of ChameleonUltra used by this adapter. */
export interface ChameleonUltraSdk {
  isConnected(): boolean;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  cmdHf14aScan(): Promise<{ uid: Uint8Array }[]>;
  cmdMf1ReadBlock(known: { block: number; keyType: number; key: Uint8Array }): Promise<Uint8Array>;
  cmdMf1WriteBlock(opts: { block: number; keyType: number; key: Uint8Array; data: Uint8Array }): Promise<void>;
}

function isStatus(err: unknown, status: number): boolean {
  return typeof err === 'object' && err !== null && (err as { status?: unknown }).status === status;
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
    let tags: { uid: Uint8Array }[];
    try {
      tags = await this.sdk.cmdHf14aScan();
    } catch (err) {
      if (isStatus(err, HF_TAG_NOT_FOUND)) return null;
      throw err;
    }
    const first = tags[0];
    return first ? new Uint8Array(first.uid) : null;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    try {
      const data = await this.sdk.cmdMf1ReadBlock({ block, keyType: MF1_KEY_A, key: Buffer.from(key) });
      return new Uint8Array(data);
    } catch (err) {
      if (isStatus(err, MF_ERR_AUTH)) throw new CardAuthError('Card keys are not factory defaults or auth failed');
      throw err;
    }
  }

  async writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> {
    try {
      await this.sdk.cmdMf1WriteBlock({ block, keyType: MF1_KEY_A, key: Buffer.from(key), data: Buffer.from(data) });
    } catch (err) {
      if (isStatus(err, MF_ERR_AUTH)) throw new CardAuthError('Card keys are not factory defaults or auth failed');
      throw err;
    }
  }
}
