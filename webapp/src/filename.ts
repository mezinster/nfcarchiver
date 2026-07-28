/**
 * Filename metadata wrapper, byte-compatible with the Flutter app
 * (lib/features/archive/data/archive_repository.dart _prependFilenameMetadata /
 *  lib/features/restore/data/restore_repository.dart _extractFilenameMetadata):
 *   [ 2-byte length, big-endian ][ UTF-8 filename (1..255) ][ original data ]
 * Applied to the plaintext before compression/encryption, so the name lives
 * inside the archive and is recoverable from the tags.
 */

const MAX_FILENAME_BYTES = 255;

export function wrapWithFilename(data: Uint8Array, fileName: string): Uint8Array {
  let nameBytes = new TextEncoder().encode(fileName);
  if (nameBytes.length > MAX_FILENAME_BYTES) nameBytes = nameBytes.subarray(0, MAX_FILENAME_BYTES);
  const out = new Uint8Array(2 + nameBytes.length + data.length);
  out[0] = (nameBytes.length >> 8) & 0xff;
  out[1] = nameBytes.length & 0xff;
  out.set(nameBytes, 2);
  out.set(data, 2 + nameBytes.length);
  return out;
}

export function unwrapFilename(data: Uint8Array): { fileName: string | null; data: Uint8Array } {
  if (data.length < 2) return { fileName: null, data };
  const nameLen = (data[0]! << 8) | data[1]!;
  if (nameLen === 0 || nameLen > MAX_FILENAME_BYTES) return { fileName: null, data };
  if (data.length < 2 + nameLen) return { fileName: null, data };
  try {
    const fileName = new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(2, 2 + nameLen));
    return { fileName, data: data.slice(2 + nameLen) };
  } catch {
    return { fileName: null, data };
  }
}
