/** Writes TS-generated interop fixtures for tool/verify_web_fixtures.dart. Run: npm run fixtures */
// Output is randomized (archive ID, salt, IV), so committed fixtures will not
// match a fresh run byte-for-byte — regenerating always produces a diff;
// that is expected.
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createChunks } from '../src/chunker.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { encrypt } from '../src/crypto.js';
import { gzipCompress } from '../src/gzip.js';
import { wrapWithFilename } from '../src/filename.js';
import { archive } from '../src/pipeline.js';
import { toHex } from './hex.js';

const original = new Uint8Array(200).map((_, i) => i % 251);
const password = '  interop-password  ';
// Compressible payload: proves gzip interop over real Huffman/LZ77 data,
// not just a stored (uncompressed) deflate block.
const textPayload = new TextEncoder().encode('nfar gzip interop '.repeat(200));

const chunks = createChunks(original, 64);
const encrypted = await encrypt(original, password);
const gzipped = await gzipCompress(original);
const gzippedText = await gzipCompress(textPayload);

const wrappedFileName = 'web report.txt';
const wrappedOriginal = new TextEncoder().encode('web body '.repeat(120));
const wrappedChunks = (await archive(wrapWithFilename(wrappedOriginal, wrappedFileName), {
  payloadSize: 720, compress: true, password,
})).map((c) => toHex(encodeChunk(c)));

const fixture = {
  payloadSize: 64,
  original: toHex(original),
  chunks: chunks.map((c) => toHex(encodeChunk(c))),
  password,
  encrypted: toHex(encrypted),
  gzipped: toHex(gzipped),
  crc32OfOriginal: crc32(original),
  originalText: toHex(textPayload),
  gzippedText: toHex(gzippedText),
  wrappedFileName,
  wrappedOriginal: toHex(wrappedOriginal),
  wrappedPassword: password,
  wrappedChunks,
};

const outPath = join(dirname(fileURLToPath(import.meta.url)), '../../test/fixtures/ts_generated.json');
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(fixture, null, 2) + '\n');
console.log(`Wrote ${outPath}`);
