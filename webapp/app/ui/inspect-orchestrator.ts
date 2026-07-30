/**
 * DOM-free inspection flow behind an injected IO seam, following the same
 * pattern as RestoreOrchestrator and ArchiveOrchestrator. The panel supplies
 * real DOM IO; tests supply a plain object, which is why nothing here needs a
 * DOM stub.
 *
 * Order matters: identity first (two frames, ~1 s), then the dump, with the
 * NFAR panel refreshed as soon as enough data blocks have arrived to describe
 * the header. That way the user sees the useful parts long before the ~64 BLE
 * round trips finish.
 */
import { dumpCard, type DumpUnit } from '../../src/inspect/card-dump.js';
import { describeNfar, type NfarDescription } from '../../src/inspect/nfar-describe.js';
import { formatIdentity, formatNfar, formatReport, formatUnitRow } from '../../src/inspect/hex-view.js';
import { USABLE_BLOCK_INDEXES, CARD_CAPACITY_BYTES } from '../../src/mifare/card-layout.js';
import { decodeNdefMime } from '../../src/nfc/ndef.js';
import { readType2Ndef } from '../../src/nfc/type2.js';
import type { ChameleonDevice } from '../../src/transport/chameleon-device.js';
import { diagnoseCard, type CardDiagnosis, type RawAntiColl } from '../diagnostics.js';
import { UnsupportedTagError } from '../../src/transport/transport.js';
import { humanError } from './errors.js';

/** NTAG stores its NDEF message from page 4 onward (pages 0-3 are UID, lock
 *  bytes and the capability container). Mirrors ntag-transport.ts. */
const NDEF_START_PAGE = 4;

export interface InspectIO {
  setIdentity(text: string): void;
  setNfar(text: string): void;
  appendRow(line: string): void;
  setProgress(text: string): void;
  setReport(text: string): void;
  setStatus(text: string): void;
}

/** The Classic path always yields raw bytes. The NTAG path can fail two
 *  structurally different ways, and collapsing them into one message would be
 *  misinformation: a TLV that has not fully arrived yet is not the same fact
 *  as a complete, valid NDEF record whose MIME type simply isn't ours. */
type NfarSource =
  | { kind: 'bytes'; bytes: Uint8Array }
  | { kind: 'no-envelope'; reason: string }
  | { kind: 'foreign'; reason: string }
  | { kind: 'unreadable'; reason: string };

/** Rebuild the NFAR chunk stream from the units seen so far, so the header can
 *  be described mid-dump.
 *
 *  The two media store the chunk differently and this is easy to get wrong:
 *  Classic holds the raw chunk bytes across the usable blocks (block 0 and every
 *  sector trailer skipped), whereas NTAG wraps the chunk in a Type-2 TLV around
 *  an NDEF MIME record starting at page 4. Concatenating raw NTAG pages yields
 *  the TLV header, not NFAR magic, so an NTAG card would always be reported as
 *  "not NFAR" without the unwrap below. */
function nfarBytesSoFar(units: DumpUnit[], isClassic: boolean): NfarSource {
  const wanted = isClassic
    ? units.filter((u) => USABLE_BLOCK_INDEXES.includes(u.index))
    : units.filter((u) => u.index >= NDEF_START_PAGE);
  const parts: Uint8Array[] = [];
  for (const u of wanted) {
    if (u.bytes === undefined) break; // a gap makes everything after it meaningless
    parts.push(u.bytes);
  }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const raw = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { raw.set(p, off); off += p.length; }
  if (isClassic) {
    // An empty stream with at least one usable block already seen means the
    // very first usable block failed (a non-factory key on sector 0, most
    // often) — describeNfar would call that "0 bytes read", which is false:
    // the dump did read blocks, they just came back auth-failed. Telling
    // those apart is the same fix already applied to the NTAG paths above.
    if (total === 0 && wanted.length > 0) {
      return { kind: 'unreadable', reason: 'the blocks holding the chunk could not be read (non-factory key?)' };
    }
    return { kind: 'bytes', bytes: raw };
  }

  // Mid-dump this throws until enough of the TLV has arrived, and it throws
  // just the same at the end for a tag with no NDEF at all — both are
  // accurately described as "no complete NDEF TLV yet", so it needs no
  // knowledge of whether the dump has finished.
  let ndef: Uint8Array;
  try {
    ndef = readType2Ndef(raw);
  } catch {
    return { kind: 'no-envelope', reason: 'no complete NDEF TLV in the pages read so far' };
  }
  // The TLV is complete but the record inside it isn't ours — a distinct,
  // permanent fact, not "0 bytes read" for a tag that was read in full.
  try {
    return { kind: 'bytes', bytes: decodeNdefMime(ndef) };
  } catch {
    return { kind: 'foreign', reason: 'valid NDEF record, but not an NFAR chunk (different MIME type)' };
  }
}

export async function runInspection(
  dev: ChameleonDevice,
  raw: RawAntiColl,
  io: InspectIO,
  signal?: AbortSignal,
): Promise<void> {
  io.setStatus('Hold the card still on the reader…');

  // The anticollision is advisory: readBlock performs its own select, so a
  // failure here must not stop the dump.
  let diag: CardDiagnosis | null = null;
  try {
    diag = await diagnoseCard(raw);
  } catch {
    diag = null;
  }

  let nfar: NfarDescription = { present: false, reason: 'no data read yet' };
  const seen: DumpUnit[] = [];

  try {
    const result = await dumpCard(dev, {
      // Fires before the first read, so identity is on screen in about a second
      // rather than after ~64 BLE round trips.
      onMeta: (meta) => { io.setIdentity(formatIdentity(meta, diag)); },
      onUnit: (unit, done, total) => {
        seen.push(unit);
        io.appendRow(formatUnitRow(unit));
        io.setProgress(done === total ? `${done}/${total} read` : `reading… ${done}/${total}`);
        // Re-describe while the NFAR extent is still growing; once the declared
        // tail is covered the description stops changing.
        if (nfar.present === false || nfar.crcValid === null) {
          const isClassic = unit.sector !== undefined;
          const src = nfarBytesSoFar(seen, isClassic);
          // Mifare Classic has a fixed, known capacity, so a declared length
          // past it is worth flagging. On NTAG the chunk arrives inside an
          // NDEF envelope whose own TLV length already bounds it, so we do not
          // guess a capacity we have not read.
          const capacityBytes = isClassic ? CARD_CAPACITY_BYTES : undefined;
          nfar = src.kind === 'bytes' ? describeNfar(src.bytes, capacityBytes) : { present: false, reason: src.reason };
          io.setNfar(formatNfar(nfar));
        }
      },
    }, signal);

    io.setNfar(formatNfar(nfar));
    io.setReport(formatReport(result.meta, diag, nfar, result.units));
    io.setStatus(
      result.aborted ? 'Stopped.'
        : result.cardLost ? 'Card left the field — re-tap and inspect again.'
        : 'Done.',
    );
  } catch (e) {
    // humanError() flattens UnsupportedTagError to a fixed generic string, but
    // this inspector builds that message specifically to be read (the SAK
    // value, which GET_VERSION byte was unrecognized) — for an inspector, that
    // text IS the result, so keep it instead of discarding it.
    io.setStatus(e instanceof UnsupportedTagError ? e.message : humanError(e));
  }
}
