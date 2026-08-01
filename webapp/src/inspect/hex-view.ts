/**
 * Text rendering of a card dump: one line per unit for the dialog, plus the
 * whole plain-text report for Copy/Download. Kept out of the DOM layer so the
 * exact output is unit-testable — the report is what gets pasted into bug
 * reports, so its content matters.
 */
import type { DumpMeta, DumpUnit } from './card-dump.js';
import type { NfarDescription } from './nfar-describe.js';

/**
 * The subset of an anticollision diagnosis this renderer needs. Declared
 * structurally rather than imported from app/diagnostics.ts: `src/` is the
 * dependency-free core and `app/` is the UI layer, so a src -> app import would
 * invert the layering even as a type-only import. `CardDiagnosis` satisfies this
 * field-for-field, so callers pass one in directly.
 */
export interface IdentityDiagnosis {
  atqa: Uint8Array;
  uidCl1: Uint8Array;
  bccReturned: number;
  bccComputed: number;
  bccValid: boolean;
  isCascade: boolean;
}

const HEX_WIDTH = 16 * 3 - 1; // "FF FF ... FF"
const ATQA_BYTES = 2;

const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

/** Printable ASCII only; everything else becomes '.' so no control character
 *  can corrupt a pasted report. */
const ascii = (b: Uint8Array): string =>
  Array.from(b, (x) => (x >= 0x20 && x <= 0x7e ? String.fromCharCode(x) : '.')).join('');

const byte = (n: number): string => `0x${n.toString(16).padStart(2, '0')}`;
const u32 = (n: number): string => n.toString(16).padStart(8, '0');

const FAILURE_TEXT: Record<NonNullable<DumpUnit['failure']>, string> = {
  'auth-failed': 'auth failed (non-factory key)',
  'not-read': 'not read (card left the field)',
  'short-read': 'short read (marginal coupling)',
};

export function formatUnitRow(u: DumpUnit): string {
  const label = u.sector === undefined
    ? `pg ${String(u.index).padStart(3)}`
    : `s${String(u.sector).padStart(2)} b${String(u.index).padStart(2)}`;
  if (u.bytes === undefined) {
    const why = u.failure ? FAILURE_TEXT[u.failure] : 'unavailable';
    return `${label}  ${`── ${why} ──`.padEnd(HEX_WIDTH)}`;
  }
  const note = u.kind === 'trailer' ? '  ← sector trailer'
    : u.kind === 'manufacturer' ? '  ← manufacturer block'
    : u.kind === 'cc' ? '  ← UID / lock / capability container'
    : '';
  return `${label}  ${hex(u.bytes).padEnd(HEX_WIDTH)}  ${ascii(u.bytes)}${note}`;
}

export function formatIdentity(meta: DumpMeta, diag: IdentityDiagnosis | null): string {
  const medium = meta.medium === 'mifare-classic-1k' ? 'Mifare Classic 1K' : meta.medium;
  const lines = [`Medium    ${medium} (SAK ${byte(meta.sak)})`, `UID       ${hex(meta.uid)}`];
  if (diag === null) {
    lines.push('BCC       anticollision failed — identity unavailable (the dump may still work)');
    return lines.join('\n');
  }
  // ATQA is a fixed 2-byte field (Classic 1K answers 04 00, LSB first). A reader
  // that returns anything else garbled the WUPA frame, and an unlabelled odd
  // value reads as a real card property in a report meant for bug reports — one
  // real tap rendered "ATQA 3F" while the anticollision right after it was clean.
  // The bytes are kept, not dropped: in an inspector the failure is information.
  const atqaNote = diag.atqa.length === ATQA_BYTES
    ? ''
    : `  ← malformed (expected ${ATQA_BYTES} bytes, got ${diag.atqa.length})`;
  lines.push(`ATQA      ${hex(diag.atqa)}${atqaNote}`);
  lines.push(`UID (CL1) ${hex(diag.uidCl1)}`);
  lines.push(
    `BCC       returned ${byte(diag.bccReturned)} · computed ${byte(diag.bccComputed)} · ` +
    (diag.bccValid ? 'OK' : 'MISMATCH'),
  );
  // A 7-byte cascade UID is entirely normal on NTAG; it is only a fault when the
  // SAK says this should be a 4-byte Mifare Classic 1K.
  if (diag.isCascade) {
    lines.push(meta.medium === 'mifare-classic-1k'
      ? 'Verdict   7-byte UID (cascade tag) — not a 4-byte Mifare Classic 1K'
      : 'Verdict   7-byte UID (cascade tag) — normal for NTAG');
  } else if (!diag.bccValid) {
    lines.push('Verdict   malformed block-0 UID (a UID-writable "magic" card); rewrite block 0 with a correct BCC');
  } else {
    lines.push('Verdict   BCC OK');
  }
  return lines.join('\n');
}

export function formatNfar(d: NfarDescription): string {
  if (!d.present) return `not NFAR: ${d.reason}`;
  const flagText = [
    d.compressed ? 'GZIP' : 'no compression',
    d.encrypted ? 'AES-256-GCM' : 'no encryption',
  ].join(', ');
  const lines = [
    `magic     NFAR  v${d.version}  flags ${byte(d.flags)} (${flagText})`,
    `archive   ${d.archiveId}`,
    `chunk     ${d.chunkIndex + 1} of ${d.totalChunks}`,
    `payload   ${d.payloadSize} B    chunk total ${d.totalLength} B`,
  ];
  if (d.crcStored === null || d.crcComputed === null) {
    lines.push('CRC32     pending — the dump has not reached the tail yet');
  } else {
    lines.push(
      `CRC32     stored ${u32(d.crcStored)} · computed ${u32(d.crcComputed)} · ` +
      (d.crcValid ? 'OK' : 'MISMATCH'),
    );
  }
  for (const w of d.warnings) lines.push(`warning   ${w}`);
  return lines.join('\n');
}

export function formatReport(
  meta: DumpMeta,
  diag: IdentityDiagnosis | null,
  nfar: NfarDescription,
  units: DumpUnit[],
): string {
  return [
    'NFC Archiver — card inspection',
    '',
    'IDENTITY',
    formatIdentity(meta, diag),
    '',
    'NFAR CHUNK',
    formatNfar(nfar),
    '',
    `RAW (${units.length} of ${meta.totalUnits} units)`,
    ...units.map(formatUnitRow),
    '',
  ].join('\n');
}
