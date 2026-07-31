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

/** Total pages per type INCLUDING the config/lock pages, not just user memory.
 *  A raw dump needs all of them; `USER_BYTES` above covers only the NDEF area. */
const TOTAL_PAGES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 45,
  [NtagType.NTAG215]: 135,
  [NtagType.NTAG216]: 231,
};

export function ntagTotalPages(t: NtagType): number {
  return TOTAL_PAGES[t];
}

export function detectNtagType(getVersion: Uint8Array): NtagType | null {
  const storage = getVersion[6];
  if (storage === 0x0f) return NtagType.NTAG213;
  if (storage === 0x11) return NtagType.NTAG215;
  if (storage === 0x13) return NtagType.NTAG216;
  return null;
}

/** Largest NFAR chunk payload whose NDEF+TLV-wrapped form fits `capacity` bytes.
 *  `capacity` is the NDEF data area available for the whole TLV (T + L + record +
 *  terminator) — for a real tag that is the Capability-Container-declared area
 *  (see ndefCapacityFromCC), NOT the raw user memory, which is what Android
 *  enforces when it reads the tag. */
export function chunkPayloadForCapacity(capacity: number): number {
  const wrappedLen = (payload: number): number =>
    wrapType2Tlv(encodeNdefMime(new Uint8Array(TOTAL_OVERHEAD + payload))).length;
  // Search downward; overhead is < 80 bytes so this is cheap.
  for (let p = capacity; p > 0; p--) {
    if (wrappedLen(p) <= capacity) return p;
  }
  return 0;
}

/** Pre-tap estimate only: max chunk payload for a tag TYPE using its raw user
 *  memory. The authoritative per-card capacity comes from the tag's Capability
 *  Container at write time (ndefCapacityFromCC → chunkPayloadForCapacity), which
 *  can be smaller (NTAG215: CC 496 B vs 504 B raw; NTAG216: 872 vs 888). */
export function ntagChunkPayloadSize(t: NtagType): number {
  return chunkPayloadForCapacity(USER_BYTES[t]);
}

/**
 * The NFC-Forum Type-2 Capability Container is 4 bytes at page 3:
 * [0]=0xE1 magic, [1]=version, [2]=MLEN (memory size / 8), [3]=access.
 * The NDEF data area available for the TLV is MLEN × 8 bytes. Android reads a
 * tag bounded by this area, so it is the capacity the writer must respect.
 * Returns null when the CC is absent/invalid (not an NDEF-formatted tag).
 */
export function ndefCapacityFromCC(cc: Uint8Array): number | null {
  if (cc.length < 4 || cc[0] !== 0xe1 || cc[2] === 0) return null;
  return cc[2]! * 8;
}

/** NDEF data area each NTAG type declares in its FACTORY Capability Container
 *  (MLEN x 8). Smaller than raw user memory: NTAG215 496 vs 504, NTAG216 872 vs
 *  888, NTAG213 144 == 144. */
const FACTORY_CC_BYTES: Record<NtagType, number> = {
  [NtagType.NTAG213]: 144,
  [NtagType.NTAG215]: 496,
  [NtagType.NTAG216]: 872,
};

export function ntagFactoryNdefCapacity(t: NtagType): number {
  return FACTORY_CC_BYTES[t];
}

/** Chunk payload for a reader that cannot read the tag's own Capability
 *  Container — Web NFC. Assumes the factory CC, which is what an unmodified tag
 *  ships with, so the bytes match what the Chameleon path writes after reading
 *  the real CC. */
export function webNfcChunkPayload(t: NtagType): number {
  return chunkPayloadForCapacity(ntagFactoryNdefCapacity(t));
}
