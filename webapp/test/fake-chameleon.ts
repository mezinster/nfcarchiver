import type { ChameleonDevice } from '../src/transport/chameleon-device.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { CardAuthError } from '../src/transport/transport.js';

function hex(u: Uint8Array): string {
  return Array.from(u, (b) => b.toString(16).padStart(2, '0')).join('');
}
function keysEqual(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

interface Card { image: Uint8Array; keyA: Uint8Array }

/** In-memory Chameleon Ultra over simulated 1K card images (64 x 16 bytes). */
export class FakeChameleon implements ChameleonDevice {
  private connected = false;
  private field: string | null = null;
  private corruptNext = false;
  private readonly cards = new Map<string, Card>();

  defineCard(uid: Uint8Array, opts?: { keyA?: Uint8Array }): void {
    this.cards.set(hex(uid), { image: new Uint8Array(64 * 16), keyA: opts?.keyA ?? FACTORY_KEY_A });
  }
  place(uid: Uint8Array): void {
    const key = hex(uid);
    if (!this.cards.has(key)) this.defineCard(uid);
    this.field = key;
  }
  remove(): void {
    this.field = null;
  }
  corruptNextWrite(): void {
    this.corruptNext = true;
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
  async scanTag(): Promise<Uint8Array | null> {
    if (this.field === null) return null;
    return Uint8Array.from(this.field.match(/../g)!.map((h) => parseInt(h, 16)));
  }

  private current(): Card {
    if (this.field === null) throw new CardAuthError('No card in field');
    return this.cards.get(this.field)!;
  }

  async readBlock(block: number, key: Uint8Array): Promise<Uint8Array> {
    const card = this.current();
    if (!keysEqual(key, card.keyA)) throw new CardAuthError(`Auth failed on block ${block}`);
    return card.image.slice(block * 16, block * 16 + 16);
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
