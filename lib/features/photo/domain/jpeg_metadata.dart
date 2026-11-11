import 'dart:typed_data';

/// Removes APP1-APP15 and COM segments from a JPEG (EXIF, XMP, GPS, comments),
/// keeping APP0/JFIF, tables, frame, scan and entropy data untouched.
/// Throws [FormatException] when [jpeg] is not a JPEG.
Uint8List stripJpegMetadata(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
    throw const FormatException('Not a JPEG');
  }
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  while (i < jpeg.length) {
    if (jpeg[i] != 0xFF) {
      throw const FormatException('Malformed JPEG marker');
    }
    // Skip fill bytes.
    while (i < jpeg.length && jpeg[i] == 0xFF) {
      i++;
    }
    if (i >= jpeg.length) throw const FormatException('Truncated JPEG');
    final marker = jpeg[i++];
    // Standalone markers (no length): TEM, RSTn, SOI, EOI.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      out.add([0xFF, marker]);
      if (marker == 0xD9) {
        // Keep anything after EOI as is (normally nothing).
        out.add(Uint8List.sublistView(jpeg, i));
        break;
      }
      continue;
    }
    if (i + 2 > jpeg.length) throw const FormatException('Truncated JPEG');
    final len = (jpeg[i] << 8) | jpeg[i + 1];
    if (len < 2 || i + len > jpeg.length) {
      throw const FormatException('Bad segment length');
    }
    final segEnd = i + len;
    if (marker == 0xDA) {
      // Scan header, then entropy data through the end of the file: nothing
      // after SOS needs stripping (metadata sits before the scan).
      out.add([0xFF, marker]);
      out.add(Uint8List.sublistView(jpeg, i));
      break;
    }
    final drop = (marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE;
    if (!drop) {
      out.add([0xFF, marker]);
      out.add(Uint8List.sublistView(jpeg, i, segEnd));
    }
    i = segEnd;
  }
  return out.takeBytes();
}
