import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatUnitRow, formatIdentity, formatNfar, formatReport } from '../src/inspect/hex-view.js';
import { describeNfar } from '../src/inspect/nfar-describe.js';
import type { DumpMeta, DumpUnit } from '../src/inspect/card-dump.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { NtagType } from '../src/nfc/type2.js';

const CLASSIC_META: DumpMeta = {
  medium: 'mifare-classic-1k', sak: 0x08,
  uid: new Uint8Array([0xb9, 0x16, 0x27, 0x51]), totalUnits: 64,
};
const DIAG = {
  atqa: new Uint8Array([0x04, 0x00]),
  uidCl1: new Uint8Array([0xb9, 0x16, 0x27, 0x51]),
  bccReturned: 0xd9, bccComputed: 0xd9, bccValid: true, isCascade: false,
};

test('a data row shows sector, block, hex and printable ASCII', () => {
  const bytes = new Uint8Array([
    0x4e, 0x46, 0x41, 0x52, 0x01, 0x00, 0x98, 0x94,
    0x4a, 0x9b, 0x17, 0x88, 0x4f, 0xcc, 0xa9, 0xf9,
  ]);
  const row = formatUnitRow({ index: 1, sector: 0, kind: 'data', bytes });
  assert.match(row, /4E 46 41 52 01 00 98 94 4A 9B 17 88 4F CC A9 F9/);
  assert.match(row, /NFAR/);
  // Non-printables must not leak control characters into the report.
  assert.ok(!/[\x00-\x1f]/.test(row.replace(/\n/g, '')), row);
});

test('a trailer row is labelled as one', () => {
  const row = formatUnitRow({ index: 3, sector: 0, kind: 'trailer', bytes: new Uint8Array(16).fill(0xff) });
  assert.match(row, /trailer/i);
});

test('failed units say why and carry no hex', () => {
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'auth-failed' }), /auth failed/i);
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'not-read' }), /not read/i);
  assert.match(formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'short-read' }), /short read/i);
  assert.ok(!/[0-9A-F]{2} [0-9A-F]{2} [0-9A-F]{2}/.test(
    formatUnitRow({ index: 8, sector: 2, kind: 'data', failure: 'auth-failed' }),
  ));
});

test('identity reports a Classic BCC verdict', () => {
  const text = formatIdentity(CLASSIC_META, DIAG);
  assert.match(text, /Mifare Classic 1K/);
  assert.match(text, /04 00/);
  assert.match(text, /B9 16 27 51/);
  assert.match(text, /0xd9/i);
  assert.match(text, /OK/);
});

test('a 7-byte cascade UID is normal on NTAG and a fault on Classic', () => {
  const cascadeDiag = { ...DIAG, uidCl1: new Uint8Array([0x88, 0x04, 0xaa, 0xbb]), isCascade: true };
  const ntagMeta: DumpMeta = {
    medium: NtagType.NTAG213, sak: 0x00, uid: new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]), totalUnits: 12,
  };
  const onNtag = formatIdentity(ntagMeta, cascadeDiag);
  assert.match(onNtag, /7-byte UID/);
  assert.ok(!/not a 4-byte|MISMATCH|fault/i.test(onNtag), `cascade is normal on NTAG: ${onNtag}`);

  const onClassic = formatIdentity(CLASSIC_META, cascadeDiag);
  assert.match(onClassic, /not a 4-byte Mifare Classic/i);
});

test('identity survives a failed anticollision', () => {
  assert.match(formatIdentity(CLASSIC_META, null), /anticollision failed/i);
});

test('the NFAR panel renders flags, ids and CRC status', () => {
  const payload = new TextEncoder().encode('Test');
  const bytes = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  const text = formatNfar(describeNfar(bytes));
  assert.match(text, /NFAR/);
  assert.match(text, /chunk\s+1 of 1/);  // the panel column-aligns, so tolerate the padding
  assert.match(text, /no compression/i);
  assert.match(text, /CRC32/);
  assert.match(text, /OK/);
});

test('the NFAR panel states why a card is not NFAR', () => {
  const text = formatNfar(describeNfar(new Uint8Array(32)));
  assert.match(text, /not NFAR/i);
  assert.match(text, /magic mismatch/);
});

test('unknown CRC status reads as pending, not as failure', () => {
  const payload = new TextEncoder().encode('Test');
  const full = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  const text = formatNfar(describeNfar(full.subarray(0, 28)));
  assert.ok(!/MISMATCH|FAILED/i.test(text), `pending must not look like corruption: ${text}`);
});

test('the report concatenates identity, NFAR and every row', () => {
  const units: DumpUnit[] = [
    { index: 0, sector: 0, kind: 'manufacturer', bytes: new Uint8Array(16) },
    { index: 1, sector: 0, kind: 'data', failure: 'auth-failed' },
  ];
  const report = formatReport(CLASSIC_META, DIAG, describeNfar(new Uint8Array(32)), units);
  assert.match(report, /Mifare Classic 1K/);
  assert.match(report, /not NFAR/i);
  assert.match(report, /auth failed/i);
  assert.ok(report.split('\n').length > 5);
});
