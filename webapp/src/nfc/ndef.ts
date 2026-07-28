/**
 * NDEF record codec for one NFAR chunk. Produces a single NDEF MIME record
 * (TNF=media, type "application/vnd.nfcarchiver.chunk") wrapping the chunk
 * bytes, byte-identical to what Android's nfc_manager.createMime emits — so a
 * tag written here is readable by the Android app and any NFC phone.
 */

export const NDEF_MIME_TYPE = 'application/vnd.nfcarchiver.chunk';
const MIME_BYTES = new TextEncoder().encode(NDEF_MIME_TYPE);

export class NdefFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NdefFormatError';
  }
}

export function encodeNdefMime(payload: Uint8Array): Uint8Array {
  const short = payload.length < 256;
  const flags = 0x80 | 0x40 | 0x02 | (short ? 0x10 : 0); // MB | ME | TNF(media) | SR?
  const lenBytes = short ? 1 : 4;
  const out = new Uint8Array(2 + lenBytes + MIME_BYTES.length + payload.length);
  let i = 0;
  out[i++] = flags;
  out[i++] = MIME_BYTES.length; // type length (33)
  if (short) {
    out[i++] = payload.length;
  } else {
    out[i++] = (payload.length >>> 24) & 0xff;
    out[i++] = (payload.length >>> 16) & 0xff;
    out[i++] = (payload.length >>> 8) & 0xff;
    out[i++] = payload.length & 0xff;
  }
  out.set(MIME_BYTES, i); i += MIME_BYTES.length;
  out.set(payload, i);
  return out;
}

function mimeEquals(bytes: Uint8Array, start: number): boolean {
  if (start + MIME_BYTES.length > bytes.length) return false;
  for (let k = 0; k < MIME_BYTES.length; k++) if (bytes[start + k] !== MIME_BYTES[k]) return false;
  return true;
}

export function decodeNdefMime(ndef: Uint8Array): Uint8Array {
  if (ndef.length < 3) throw new NdefFormatError('NDEF record too short');
  const flags = ndef[0]!;
  const tnf = flags & 0x07;
  if (tnf !== 0x02) throw new NdefFormatError(`Unexpected TNF ${tnf} (want media)`);
  const short = (flags & 0x10) !== 0;
  const typeLen = ndef[1]!;
  let i = 2;
  let payloadLen: number;
  if (short) {
    payloadLen = ndef[i]!; i += 1;
  } else {
    payloadLen = ((ndef[i]! << 24) | (ndef[i + 1]! << 16) | (ndef[i + 2]! << 8) | ndef[i + 3]!) >>> 0;
    i += 4;
  }
  if (typeLen !== MIME_BYTES.length || !mimeEquals(ndef, i)) {
    throw new NdefFormatError('Not an NFAR NDEF record (MIME type mismatch)');
  }
  i += typeLen;
  if (i + payloadLen > ndef.length) throw new NdefFormatError('NDEF payload runs past end of record');
  return ndef.slice(i, i + payloadLen);
}
