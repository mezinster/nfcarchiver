/**
 * Content type for a restored file, resolved from its name.
 *
 * A `new Blob([bytes])` with no type downloads as application/octet-stream.
 * The bytes are correct either way, but on Android the viewer launched from
 * the download receives that type, finds no charset, and falls back to a
 * platform default — which renders UTF-8 Cyrillic as mojibake while leaving
 * ASCII looking perfect. Declaring the charset is what tells it how to decode.
 *
 * This is the browser-side twin of the `share_plus` MIME rule in CLAUDE.md,
 * where Android's ContentResolver reports application/octet-stream for the
 * same reason. The Flutter app uses the `mime` package; the webapp core takes
 * no runtime dependencies, so this is a small table of what we actually
 * archive rather than a full registry.
 */

/** Types whose bytes we produce as UTF-8 and whose viewers must be told so. */
const TEXT_TYPES: Record<string, string> = {
  txt: 'text/plain',
  md: 'text/markdown',
  csv: 'text/csv',
  html: 'text/html',
  xml: 'text/xml',
};

/** Types carrying their own encoding, for which a charset parameter is
 *  meaningless or (for JSON, per RFC 8259) undefined. */
const BINARY_TYPES: Record<string, string> = {
  json: 'application/json',
  pdf: 'application/pdf',
  zip: 'application/zip',
  gz: 'application/gzip',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
};

export function mimeForFilename(name: string): string {
  const dot = name.lastIndexOf('.');
  // dot === 0 is a dotfile (".bashrc"): the name IS the suffix, not an
  // extension. dot === name.length - 1 is a trailing dot with nothing after it.
  if (dot <= 0 || dot === name.length - 1) return 'application/octet-stream';
  const ext = name.slice(dot + 1).toLowerCase();
  const text = TEXT_TYPES[ext];
  if (text !== undefined) return `${text};charset=utf-8`;
  return BINARY_TYPES[ext] ?? 'application/octet-stream';
}
