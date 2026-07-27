import type { Transport } from './transport.js';

/** In-memory bank of "tags" for tests and demos. Each writeChunk fills the next tag. */
export class MockTransport implements Transport {
  readonly name = 'mock';
  private readonly tags: Uint8Array[] = [];
  private presented = 0;

  constructor(private readonly capacity = 512) {}

  async connect(): Promise<void> {}
  async disconnect(): Promise<void> {}

  async detectCapacity(): Promise<number> {
    return this.capacity;
  }

  presentTag(index: number): void {
    this.presented = index;
  }

  get tagCount(): number {
    return this.tags.length;
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    if (bytes.length > this.capacity) {
      throw new RangeError(`Chunk (${bytes.length} B) exceeds tag capacity (${this.capacity} B)`);
    }
    this.tags.push(bytes.slice());
  }

  async readChunk(): Promise<Uint8Array> {
    const tag = this.tags[this.presented];
    if (tag === undefined) {
      throw new RangeError(`No tag at index ${this.presented}`);
    }
    return tag.slice();
  }
}
