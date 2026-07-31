/**
 * Transport over the phone's own NFC radio via Web NFC. NDEF only — no raw page
 * access, so no Mifare Classic and no card inspection.
 *
 * Web NFC inverts the Chameleon's model: `write()` IS the tap, rather than an
 * operation on a tag already waited for. To keep one tap per card, awaitTag()
 * caches the reading it received and peek/read serve from that cache; writeChunk
 * then writes to the tag still in the field.
 */
import { encodeNdefMime } from '../nfc/ndef.js';
import { NtagType } from '../nfc/type2.js';
import { ntagFactoryNdefCapacity, webNfcChunkPayload } from '../nfc/type2.js';
import { NfarFormatError } from '../chunk.js';
import type { NdefIO, NdefReading } from './ndef-io.js';
import { uidFromSerialNumber } from './ndef-io.js';
import { CardCapacityError } from '../mifare/card-layout.js';
import type { PresentedTag, Transport } from './transport.js';

const NFAR_MIME = 'application/vnd.nfcarchiver.chunk';

export class WebNfcTransport implements Transport {
  readonly name = 'web-nfc';
  private current: NdefReading | null = null;

  /** `tagType` is the user's explicit choice: Web NFC exposes no capability
   *  container, so capacity cannot be discovered from the card. */
  constructor(private readonly io: NdefIO, private readonly tagType: NtagType) {}

  async connect(): Promise<void> {
    // Nothing to open: the browser owns the radio. Present for interface parity.
  }

  async disconnect(): Promise<void> {
    this.current = null;
    this.io.stop();
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    const reading = await this.io.awaitReading(opts);
    this.current = reading;
    return {
      uid: uidFromSerialNumber(reading.serialNumber),
      capacityBytes: ntagFactoryNdefCapacity(this.tagType),
      maxChunkPayload: webNfcChunkPayload(this.tagType),
    };
  }

  /** The NFAR chunk carried by the cached reading, or null. */
  private cachedChunk(): Uint8Array | null {
    if (this.current === null) return null;
    for (const record of this.current.records) {
      if (record.recordType !== 'mime' || record.mediaType !== NFAR_MIME) continue;
      if (record.data === undefined) continue;
      return record.data;
    }
    return null;
  }

  async peekIsNfar(): Promise<boolean> {
    return this.cachedChunk() !== null;
  }

  async readChunk(): Promise<Uint8Array> {
    const bytes = this.cachedChunk();
    if (bytes === null) throw new NfarFormatError('This tag holds no NFAR NDEF data');
    return bytes;
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const max = webNfcChunkPayload(this.tagType);
    const wrapped = encodeNdefMime(bytes).length;
    if (wrapped > ntagFactoryNdefCapacity(this.tagType)) {
      throw new CardCapacityError(
        `Chunk wraps to ${wrapped} B; ${this.tagType} holds ` +
        `${ntagFactoryNdefCapacity(this.tagType)} B of NDEF (max payload ${max} B)`,
      );
    }
    await this.io.write([{ recordType: 'mime', mediaType: NFAR_MIME, data: bytes }]);
  }
}
