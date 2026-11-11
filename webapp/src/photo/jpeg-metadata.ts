/**
 * Removes APP1-APP15 and COM segments from a JPEG (EXIF, XMP, GPS, comments),
 * keeping APP0/JFIF, tables, frame, scan and entropy data untouched, and drops
 * everything after the first EOI (an appended gain map would carry its own
 * metadata). Port of lib/features/photo/domain/jpeg_metadata.dart.
 * Throws on non-JPEG or malformed input.
 */
export function stripJpegMetadata(jpeg: Uint8Array): Uint8Array {
  if (jpeg.length < 4 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8) throw new Error('Not a JPEG');
  const out: number[] = [0xff, 0xd8];
  const copy = (from: number, to: number): void => {
    for (let k = from; k < to; k++) out.push(jpeg[k]!);
  };
  let i = 2;
  while (i < jpeg.length) {
    if (jpeg[i] !== 0xff) throw new Error('Malformed JPEG marker');
    while (i < jpeg.length && jpeg[i] === 0xff) i++; // fill bytes
    if (i >= jpeg.length) throw new Error('Truncated JPEG');
    const marker = jpeg[i++]!;
    // Standalone markers (no length): TEM, RSTn, SOI, EOI.
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd9)) {
      out.push(0xff, marker);
      if (marker === 0xd9) break;
      continue;
    }
    if (i + 2 > jpeg.length) throw new Error('Truncated JPEG');
    const len = (jpeg[i]! << 8) | jpeg[i + 1]!;
    if (len < 2 || i + len > jpeg.length) throw new Error('Bad segment length');
    const segEnd = i + len;
    if (marker === 0xda) {
      // Scan header, then entropy data up to the next real marker: inside
      // entropy data FF is followed only by 00 or D0-D7.
      let j = segEnd;
      while (
        j + 1 < jpeg.length &&
        !(jpeg[j] === 0xff && jpeg[j + 1] !== 0x00 && !(jpeg[j + 1]! >= 0xd0 && jpeg[j + 1]! <= 0xd7))
      ) {
        j++;
      }
      if (j + 1 >= jpeg.length) throw new Error('Truncated JPEG');
      out.push(0xff, marker);
      copy(i, j);
      i = j;
      continue;
    }
    const drop = (marker >= 0xe1 && marker <= 0xef) || marker === 0xfe;
    if (!drop) {
      out.push(0xff, marker);
      copy(i, segEnd);
    }
    i = segEnd;
  }
  return Uint8Array.from(out);
}
