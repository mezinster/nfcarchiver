/**
 * Raw card dump for the inspector. Reads every block (Mifare Classic) or page
 * group (NTAG) and reports each unit the moment it arrives, so the UI can
 * render top-down instead of waiting ~15-25 s for 64 BLE round trips.
 *
 * Talks to the ChameleonDevice seam directly: a raw dump is not a chunk
 * operation, so the Transport interface stays untouched. Read-only throughout.
 *
 * A per-sector auth failure becomes a marked unit rather than a throw — a card
 * with one custom-keyed sector is still mostly readable, and that partial view
 * is itself diagnostic. A NON-auth failure means the card has almost certainly
 * left the field, so the dump stops and marks the remainder rather than grinding
 * through dozens more failing round trips.
 */
import { BLOCK_SIZE } from '../mifare/card-layout.js';
import { detectNtagType, ntagTotalPages, type NtagType } from '../nfc/type2.js';
import { FACTORY_KEY_A, type ChameleonDevice } from '../transport/chameleon-device.js';
import { CardAuthError, TagTimeoutError, UnsupportedTagError } from '../transport/transport.js';

export type UnitKind = 'manufacturer' | 'data' | 'trailer' | 'cc';
export type UnitFailure = 'auth-failed' | 'not-read' | 'short-read';

export interface DumpUnit {
  /** Block number (Classic) or first page of the group (NTAG). */
  index: number;
  /** Sector number for Classic; undefined for NTAG. */
  sector?: number;
  kind: UnitKind;
  /** Absent when the read failed. */
  bytes?: Uint8Array;
  failure?: UnitFailure;
}

export interface DumpMeta {
  medium: 'mifare-classic-1k' | NtagType;
  sak: number;
  uid: Uint8Array;
  totalUnits: number;
}

export interface DumpResult {
  meta: DumpMeta;
  units: DumpUnit[];
  /** The caller aborted (dialog closed). */
  aborted: boolean;
  /** A non-auth read failure stopped the dump — usually the card left the field. */
  cardLost: boolean;
}

const CLASSIC_BLOCKS = 64;
const PAGES_PER_READ = 4;

export interface DumpCallbacks {
  /** Fires as soon as the medium is known — BEFORE any block is read — so the
   *  UI can show identity in about a second instead of after ~64 round trips. */
  onMeta?: (meta: DumpMeta) => void;
  onUnit: (u: DumpUnit, done: number, total: number) => void;
}

export async function dumpCard(
  dev: ChameleonDevice,
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  const tag = await dev.scanTag();
  if (tag === null) throw new TagTimeoutError('No card in the field — hold one on the reader');
  if (tag.sak === 0x08) return dumpClassic(dev, tag, cb, signal);
  if (tag.sak === 0x00) return dumpNtag(dev, tag, cb, signal);
  throw new UnsupportedTagError(
    `Unsupported tag (SAK 0x${tag.sak.toString(16)}) — Mifare Classic 1K and NTAG213/215/216 can be inspected`,
  );
}

function classicKind(block: number): UnitKind {
  if (block === 0) return 'manufacturer';
  return block % 4 === 3 ? 'trailer' : 'data';
}

async function dumpClassic(
  dev: ChameleonDevice,
  tag: { uid: Uint8Array; sak: number },
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  const meta: DumpMeta = {
    medium: 'mifare-classic-1k', sak: tag.sak, uid: tag.uid, totalUnits: CLASSIC_BLOCKS,
  };
  cb.onMeta?.(meta);
  const onUnit = cb.onUnit;
  const units: DumpUnit[] = [];
  let aborted = false;
  let cardLost = false;

  for (let block = 0; block < CLASSIC_BLOCKS; block++) {
    if (signal?.aborted) { aborted = true; break; }
    const base = { index: block, sector: Math.floor(block / 4), kind: classicKind(block) };
    let unit: DumpUnit;
    try {
      const bytes = await dev.readBlock(block, FACTORY_KEY_A);
      unit = bytes.length === BLOCK_SIZE ? { ...base, bytes } : { ...base, failure: 'short-read' };
    } catch (e) {
      if (e instanceof CardAuthError) {
        unit = { ...base, failure: 'auth-failed' };
      } else {
        // The card has almost certainly left the field. Report this block and
        // every remaining one as not-read, then stop.
        cardLost = true;
        for (let rest = block; rest < CLASSIC_BLOCKS; rest++) {
          const u: DumpUnit = {
            index: rest, sector: Math.floor(rest / 4), kind: classicKind(rest), failure: 'not-read',
          };
          units.push(u);
          onUnit(u, rest + 1, CLASSIC_BLOCKS);
        }
        break;
      }
    }
    units.push(unit);
    onUnit(unit, block + 1, CLASSIC_BLOCKS);
  }
  return { meta, units, aborted, cardLost };
}

async function dumpNtag(
  dev: ChameleonDevice,
  tag: { uid: Uint8Array; sak: number },
  cb: DumpCallbacks,
  signal?: AbortSignal,
): Promise<DumpResult> {
  let version: Uint8Array;
  try {
    version = await dev.transceive14a(new Uint8Array([0x60]), {
      autoSelect: true, appendCrc: true, checkResponseCrc: true,
    });
  } catch {
    throw new UnsupportedTagError('Tag does not answer NTAG GET_VERSION');
  }
  const type = detectNtagType(version);
  if (type === null) {
    throw new UnsupportedTagError('Unsupported NTAG (GET_VERSION storage byte unrecognized)');
  }

  const pages = ntagTotalPages(type);
  const groups = Math.ceil(pages / PAGES_PER_READ);
  const meta: DumpMeta = { medium: type, sak: tag.sak, uid: tag.uid, totalUnits: groups };
  cb.onMeta?.(meta);
  const onUnit = cb.onUnit;
  const units: DumpUnit[] = [];
  let aborted = false;
  let cardLost = false;

  for (let group = 0; group < groups; group++) {
    if (signal?.aborted) { aborted = true; break; }
    const startPage = group * PAGES_PER_READ;
    const pagesHere = Math.min(PAGES_PER_READ, pages - startPage);
    const want = pagesHere * 4;
    const isFinal = group === groups - 1;
    // Group 0 is UID + lock bytes + Capability Container.
    const base = { index: startPage, kind: (group === 0 ? 'cc' : 'data') as UnitKind };
    let unit: DumpUnit;
    try {
      const resp = await dev.transceive14a(new Uint8Array([0x30, startPage]), {
        autoSelect: true, appendCrc: true, checkResponseCrc: true,
      });
      // A real READ always returns 4 pages and WRAPS to page 0 near the end of
      // memory, so truncate to the pages that actually exist. FakeChameleon
      // does not wrap — it returns a short slice — so a short response is
      // acceptable on the FINAL group only. Anywhere else a short read means
      // marginal RF coupling (see the CardReadError work in PR #42) and is a
      // failure. Same symptom, opposite meaning, told apart by position.
      if (resp.length >= want) {
        unit = { ...base, bytes: resp.subarray(0, want) };
      } else if (isFinal) {
        unit = { ...base, bytes: resp };
      } else {
        unit = { ...base, failure: 'short-read' };
      }
    } catch (e) {
      if (e instanceof CardAuthError) {
        unit = { ...base, failure: 'auth-failed' };
      } else {
        cardLost = true;
        for (let rest = group; rest < groups; rest++) {
          const u: DumpUnit = {
            index: rest * PAGES_PER_READ,
            kind: (rest === 0 ? 'cc' : 'data') as UnitKind,
            failure: 'not-read',
          };
          units.push(u);
          onUnit(u, rest + 1, groups);
        }
        break;
      }
    }
    units.push(unit);
    onUnit(unit, group + 1, groups);
  }
  return { meta, units, aborted, cardLost };
}
