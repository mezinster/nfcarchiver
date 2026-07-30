import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError } from '../src/transport/transport.js';
import { NtagType } from '../src/nfc/type2.js';

function hex(u: Uint8Array): string {
  return Array.from(u, (b) => b.toString(16).padStart(2, '0')).join('');
}
function keysEqual(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

// page counts: 213=45, 215=135, 216=231
const NTAG_PAGES: Record<NtagType, number> = { NTAG213: 45, NTAG215: 135, NTAG216: 231 };
const NTAG_STORAGE: Record<NtagType, number> = { NTAG213: 0x0f, NTAG215: 0x11, NTAG216: 0x13 };
// Factory Capability Container MLEN (NDEF data area / 8) programmed at page 3.
// NTAG213 144 B (== raw), NTAG215 496 B (< 504 raw), NTAG216 872 B (< 888 raw).
const NTAG_CC_MLEN: Record<NtagType, number> = { NTAG213: 0x12, NTAG215: 0x3e, NTAG216: 0x6d };

interface Card { image: Uint8Array; keyA: Uint8Array; sak: number; ntag?: { type: NtagType; pages: Uint8Array } }

/** In-memory Chameleon Ultra over simulated 1K card images (64 x 16 bytes). */
export class FakeChameleon implements ChameleonDevice {
  private connected = false;
  private field: string | null = null;
  private corruptNext = false;
  private truncateNext: number | null = null;
  private readonly cards = new Map<string, Card>();

  defineCard(uid: Uint8Array, opts?: { keyA?: Uint8Array; sak?: number }): void {
    this.cards.set(hex(uid), {
      image: new Uint8Array(64 * 16),
      keyA: opts?.keyA ?? FACTORY_KEY_A,
      sak: opts?.sak ?? 0x08,
    });
  }
  place(uid: Uint8Array): void {
    const key = hex(uid);
    if (!this.cards.has(key)) this.defineCard(uid);
    this.field = key;
  }
  /** Idempotent like place(): defines the NTAG only if new, so re-presenting the
   *  same UID keeps its written pages (needed for write→read-back tests). */
  placeNtag(uid: Uint8Array, type: NtagType): void {
    const key = hex(uid);
    if (!this.cards.has(key)) {
      const pages = new Uint8Array(NTAG_PAGES[type] * 4);
      pages.set([0xe1, 0x10, NTAG_CC_MLEN[type], 0x00], 3 * 4); // Capability Container at page 3
      this.cards.set(key, {
        image: new Uint8Array(64 * 16), keyA: FACTORY_KEY_A, sak: 0x00,
        ntag: { type, pages },
      });
    }
    this.field = key;
  }
  remove(): void {
    this.field = null;
  }
  corruptNextWrite(): void {
    this.corruptNext = true;
  }
  /** Simulate one marginal RF read: the reader returns fewer bytes than a full
   *  block/page-group without reporting an error, as the Chameleon does when
   *  coupling is poor. */
  truncateNextRead(keepBytes = 4): void {
    this.truncateNext = keepBytes;
  }
  blockOf(uid: Uint8Array, block: number): Uint8Array {
    return this.cards.get(hex(uid))!.image.slice(block * 16, block * 16 + 16);
  }

  isConnected(): boolean {
    return this.connected;
  }
  async connect(): Promise<void> {
    this.connected = true;
  }
  async disconnect(): Promise<void> {
    this.connected = false;
  }
  async scanTag(): Promise<{ uid: Uint8Array; sak: number } | null> {
    if (this.field === null) return null;
    const card = this.cards.get(this.field)!;
    return { uid: Uint8Array.from(this.field.match(/../g)!.map((h) => parseInt(h, 16))), sak: card.sak };
  }

  async transceive14a(
    data: Uint8Array,
    _opts?: { appendCrc?: boolean; autoSelect?: boolean; checkResponseCrc?: boolean },
  ): Promise<Uint8Array> {
    const card = this.current();
    const ntag = card.ntag;
    if (!ntag) throw new CardAuthError('Not an NTAG card in field');
    const cmd = data[0];
    if (cmd === 0x60) { // GET_VERSION
      return new Uint8Array([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, NTAG_STORAGE[ntag.type], 0x03]);
    }
    if (cmd === 0x30) { // READ page..page+3 (16 bytes)
      const page = data[1]!;
      const full = ntag.pages.slice(page * 4, page * 4 + 16);
      if (this.truncateNext !== null) {
        const keep = this.truncateNext;
        this.truncateNext = null;
        return full.slice(0, keep);
      }
      return full;
    }
    if (cmd === 0xa2) { // WRITE one page
      const page = data[1]!;
      ntag.pages.set(data.subarray(2, 6), page * 4);
      return new Uint8Array([0x0a]); // ACK
    }
    throw new CardAuthError(`Unsupported NTAG command 0x${cmd?.toString(16)}`);
  }

  private current(): Card {
    if (this.field === null) throw new CardAuthError('No card in field');
    return this.cards.get(this.field)!;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    const card = this.current();
    if (!keysEqual(key, card.keyA)) throw new CardAuthError(`Auth failed on block ${block}`);
    const full = card.image.slice(block * 16, block * 16 + 16);
    if (this.truncateNext !== null) {
      const keep = this.truncateNext;
      this.truncateNext = null;
      return full.slice(0, keep);
    }
    return full;
  }

  async writeBlock(block: number, key: Uint8Array, data: Uint8Array): Promise<void> {
    const card = this.current();
    if (!keysEqual(key, card.keyA)) throw new CardAuthError(`Auth failed on block ${block}`);
    const toWrite = data.slice(0, 16);
    if (this.corruptNext) {
      this.corruptNext = false;
      toWrite[0] = (toWrite[0] ?? 0) ^ 0xff; // flip a bit so read-back verification fails
    }
    card.image.set(toWrite, block * 16);
  }
}
