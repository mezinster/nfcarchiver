/**
 * Writes the cross-language reference report for the Flutter port.
 *
 * Builds the DumpMeta / DumpUnit[] / NfarDescription / IdentityDiagnosis
 * structures DIRECTLY rather than running a fake device, so the fixture pins
 * the FORMATTERS and nothing else. Coupling two independent fake devices would
 * make the test fail for reasons that have nothing to do with formatting.
 *
 * Run: npx tsc && node dist/test/write_inspect_fixture.js
 * Output: ../test/fixtures/inspect_report.txt (the Flutter test tree)
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { DumpMeta, DumpUnit } from '../src/inspect/card-dump.js';
import type { NfarDescription } from '../src/inspect/nfar-describe.js';
import { formatReport, type IdentityDiagnosis } from '../src/inspect/hex-view.js';

/** Deterministic block contents: byte i of block b is (0x42 + b + i) & 0xff. */
function blockBytes(b: number): Uint8Array {
  return new Uint8Array(Array.from({ length: 16 }, (_, i) => (0x42 + b + i) & 0xff));
}

const meta: DumpMeta = {
  medium: 'mifare-classic-1k',
  sak: 0x08,
  uid: new Uint8Array([0xde, 0xad, 0xbe, 0xef]),
  totalUnits: 64,
};

const diag: IdentityDiagnosis = {
  // ATQA 0x0004 as a Classic 1K actually puts it on the wire: LSB first.
  atqa: new Uint8Array([0x04, 0x00]),
  uidCl1: new Uint8Array([0xde, 0xad, 0xbe, 0xef]),
  bccReturned: 0xde ^ 0xad ^ 0xbe ^ 0xef,
  bccComputed: 0xde ^ 0xad ^ 0xbe ^ 0xef,
  bccValid: true,
  isCascade: false,
};

// Cover every kind and every failure mode in one artefact, so the fixture
// exercises each branch of formatUnitRow rather than only the happy path.
const units: DumpUnit[] = [];
for (let block = 0; block < 12; block++) {
  const kind = block === 0 ? 'manufacturer' : block % 4 === 3 ? 'trailer' : 'data';
  const base = { index: block, sector: Math.floor(block / 4), kind } as const;
  if (block === 5) units.push({ ...base, failure: 'auth-failed' });
  else if (block === 6) units.push({ ...base, failure: 'short-read' });
  else if (block === 11) units.push({ ...base, failure: 'not-read' });
  else units.push({ ...base, bytes: blockBytes(block) });
}
// One NTAG-shaped unit so the `pg NNN` label and the cc note are covered too.
units.push({ index: 0, kind: 'cc', bytes: blockBytes(99) });

const nfar: NfarDescription = {
  present: true,
  version: 1,
  flags: 0x03,
  compressed: true,
  encrypted: true,
  archiveId: 'a0a1a2a3-a4a5-a6a7-a8a9-aaabacadaeaf',
  chunkIndex: 2,
  totalChunks: 8,
  payloadSize: 720,
  totalLength: 752,
  crcStored: 0x1234abcd,
  crcComputed: 0x1234abcd,
  crcValid: true,
  warnings: ['declared length 752 B exceeds the tag’s 700 B capacity'],
};

const here = dirname(fileURLToPath(import.meta.url));
// Compiled to webapp/dist/test/, so the Flutter test tree is three levels up.
const out = join(here, '..', '..', '..', 'test', 'fixtures', 'inspect_report.txt');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, formatReport(meta, diag, nfar, units), 'utf8');
console.log(`wrote ${out}`);
