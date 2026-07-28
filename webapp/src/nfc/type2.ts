/**
 * NFC-Forum Type-2 tag helpers: NDEF-message TLV framing (written from page 4),
 * NTAG type detection, and per-type capacity math. Mirrors the Android app's
 * maxPayloadForNdefCapacity so the same data fits the same tags.
 */

import { NdefFormatError, encodeNdefMime } from './ndef.js';
import { TOTAL_OVERHEAD } from '../chunk.js';

export function wrapType2Tlv(ndef: Uint8Array): Uint8Array {
  if (ndef.length < 0xff) {
    const out = new Uint8Array(2 + ndef.length + 1);
    out[0] = 0x03;
    out[1] = ndef.length;
    out.set(ndef, 2);
    out[out.length - 1] = 0xfe;
    return out;
  }
  const out = new Uint8Array(4 + ndef.length + 1);
  out[0] = 0x03;
  out[1] = 0xff;
  out[2] = (ndef.length >>> 8) & 0xff;
  out[3] = ndef.length & 0xff;
  out.set(ndef, 4);
  out[out.length - 1] = 0xfe;
  return out;
}

export function readType2Ndef(memory: Uint8Array): Uint8Array {
  let i = 0;
  while (i < memory.length) {
    const tag = memory[i]!;
    if (tag === 0x00) { i += 1; continue; } // NULL TLV
    if (tag === 0xfe) break; // terminator
    if (i + 1 >= memory.length) break;
    let len = memory[i + 1]!;
    let valueStart = i + 2;
    if (len === 0xff) {
      len = (memory[i + 2]! << 8) | memory[i + 3]!;
      valueStart = i + 4;
    }
    if (tag === 0x03) {
      if (valueStart + len > memory.length) throw new NdefFormatError('NDEF TLV runs past end of tag memory');
      return memory.slice(valueStart, valueStart + len);
    }
    i = valueStart + len; // skip lock (0x01) / memory-control (0x02) / other TLVs
  }
  throw new NdefFormatError('No NDEF TLV found in tag memory');
}

export enum NtagType {
  NTAG213 = 'NTAG213',
  NTAG215 = 'NTAG215',
  NTAG216 = 'NTAG216',
}

const USER_BYTES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 144,
  [NtagType.NTAG215]: 504,
  [NtagType.NTAG216]: 888,
};

export function ntagUserBytes(t: NtagType): number {
  return USER_BYTES[t];
}

export function detectNtagType(getVersion: Uint8Array): NtagType | null {
  const storage = getVersion[6];
  if (storage === 0x0f) return NtagType.NTAG213;
  if (storage === 0x11) return NtagType.NTAG215;
  if (storage === 0x13) return NtagType.NTAG216;
  return null;
}

/** Largest NFAR chunk payload whose NDEF+TLV-wrapped form fits this tag's user memory. */
export function ntagChunkPayloadSize(t: NtagType): number {
  const cap = USER_BYTES[t];
  const wrappedLen = (payload: number): number =>
    wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
  // Search downward from the raw capacity; overhead is < 80 bytes so this is cheap.
  for (let p = cap; p > 0; p--) {
    if (wrappedLen(p) <= cap) return p;
  }
  return 0;
}
