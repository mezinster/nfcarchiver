/** Writes TS-generated interop fixtures for tool/verify_web_fixtures.dart. Run: npm run fixtures */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createChunks } from '../src/chunker.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { encrypt } from '../src/crypto.js';
import { gzipCompress } from '../src/gzip.js';
import { toHex } from './hex.js';

const original = new Uint8Array(200).map((_, i) => i % 251);
const password = '  interop-password  ';

const chunks = createChunks(original, 64);
const encrypted = await encrypt(original, password);
const gzipped = await gzipCompress(original);

const fixture = {
  payloadSize: 64,
  original: toHex(original),
  chunks: chunks.map((c) => toHex(encodeChunk(c))),
  password,
  encrypted: toHex(encrypted),
  gzipped: toHex(gzipped),
  crc32OfOriginal: crc32(original),
};

const outPath = join(dirname(fileURLToPath(import.meta.url)), '../../test/fixtures/ts_generated.json');
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(fixture, null, 2) + '\n');
console.log(`Wrote ${outPath}`);
