/**
 * Transport over a Chameleon Ultra reading/writing NFAR chunks on NTAG213/215/216
 * as NDEF (Type-2). One NDEF-wrapped chunk per tag, matching the Android format.
 */

import { CardCapacityError } from '../mifare/card-layout.js';
import { encodeNdefMime, decodeNdefMime, NdefFormatError } from '../nfc/ndef.js';
import { wrapType2Tlv, readType2Ndef, detectNtagType, ntagUserBytes, ntagChunkPayloadSize, type NtagType } from '../nfc/type2.js';
import type { ChameleonDevice } from './chameleon-device.js';
import { NfarFormatError, TOTAL_OVERHEAD } from '../chunk.js';
import { TagTimeoutError, UnsupportedTagError, WriteVerifyError, type PresentedTag, type Transport } from './transport.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
const NDEF_START_PAGE = 4;

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export class NtagTransport implements Transport {
  readonly name = 'ntag';
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

  private async detectType(): Promise<NtagType> {
    let v: Uint8Array;
    try {
      v = await this.device.transceive14a(new Uint8Array([0x60]), { autoSelect: true, appendCrc: true, checkResponseCrc: true });
    } catch {
      throw new UnsupportedTagError('Tag does not support NTAG GET_VERSION');
    }
    const t = detectNtagType(v);
    if (t === null) throw new UnsupportedTagError('Unsupported NTAG (GET_VERSION storage byte unrecognized)');
    return t;
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const timeoutMs = opts?.timeoutMs ?? this.defaultTimeoutMs;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (opts?.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const tag = await this.device.scanTag();
      if (tag !== null) {
        const type = await this.detectType();
        return { uid: tag.uid, capacityBytes: ntagUserBytes(type) };
      }
      if (Date.now() >= deadline) throw new TagTimeoutError(`No tag presented within ${timeoutMs}ms`);
      await delay(this.pollMs);
    }
  }

  /** Read `pages` starting at `startPage`, 16 bytes per READ. */
  private async readMemory(startPage: number, byteCount: number): Promise<Uint8Array> {
    const out = new Uint8Array(Math.ceil(byteCount / 16) * 16);
    for (let off = 0; off < out.length; off += 16) {
      const resp = await this.device.transceive14a(new Uint8Array([0x30, startPage + off / 4]), { autoSelect: true, appendCrc: true, checkResponseCrc: true });
      out.set(resp.subarray(0, 16), off);
    }
    return out.subarray(0, byteCount);
  }

  async peekIsNfar(): Promise<boolean> {
    // Reuse readChunk: it fully parses TLV → NDEF → chunk and throws on any
    // blank/foreign tag. Correct for large chunks too (a 32-byte peek would
    // wrongly fail an NTAG216-sized record whose payload runs past 32 bytes).
    try {
      await this.readChunk();
      return true;
    } catch (e) {
      if (e instanceof NfarFormatError || e instanceof NdefFormatError) return false;
      throw e;
    }
  }

  async readChunk(): Promise<Uint8Array> {
    // First 16 bytes give the TLV header + start of the NDEF; parse the TLV length to know the total.
    const head = await this.readMemory(NDEF_START_PAGE, 16);
    if (head[0] !== 0x03) throw new NfarFormatError('No NDEF TLV on this tag');
    let tlvLen = head[1]!;
    let ndefStart = 2;
    if (tlvLen === 0xff) { tlvLen = (head[2]! << 8) | head[3]!; ndefStart = 4; }
    const totalTlvBytes = ndefStart + tlvLen + 1; // + terminator
    const memory = await this.readMemory(NDEF_START_PAGE, totalTlvBytes);
    return decodeNdefMime(readType2Ndef(memory));
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const type = await this.detectType();
    if (bytes.length > TOTAL_OVERHEAD + ntagChunkPayloadSize(type)) {
      throw new CardCapacityError(`Chunk ${bytes.length} B exceeds ${type} capacity`);
    }
    const tlv = wrapType2Tlv(encodeNdefMime(bytes));
    const padded = new Uint8Array(Math.ceil(tlv.length / 4) * 4);
    padded.set(tlv);
    const pageCount = padded.length / 4;
    for (let p = 0; p < pageCount; p++) {
      // NTAG WRITE returns a 4-bit ACK/NAK with no CRC, so checkResponseCrc is
      // intentionally omitted here (unlike the READ/GET_VERSION transceives above).
      await this.device.transceive14a(
        new Uint8Array([0xa2, NDEF_START_PAGE + p, ...padded.subarray(p * 4, p * 4 + 4)]),
        { autoSelect: true, appendCrc: true },
      );
    }
    // Read-back verify.
    const readBack = await this.readMemory(NDEF_START_PAGE, padded.length);
    if (!bytesEqual(readBack, padded)) throw new WriteVerifyError('NTAG read-back does not match written pages');
  }
}
