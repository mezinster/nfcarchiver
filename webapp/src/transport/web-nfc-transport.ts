/**
 * Transport over the phone's own NFC radio via Web NFC. NDEF only — no raw page
 * access, so no Mifare Classic and no card inspection.
 *
 * Web NFC inverts the Chameleon's model: `write()` IS the tap, rather than an
 * operation on a tag already waited for. To keep one tap per card, awaitTag()
 * caches the reading it received and peek/read serve from that cache; writeChunk
 * then writes to the tag still in the field.
 *
 * Deviation from the `Transport` contract: `writeChunk()` does NOT read back and
 * verify, unlike `NtagTransport`. Web NFC has no way to re-read the tag without
 * costing a second tap, and this transport is built around one tap per card.
 * Instead it invalidates the cache on a successful write, so a stale peek/read
 * afterwards cannot report pre-write content as current — callers that need
 * verification must re-tap and call `awaitTag()` again.
 */
import { NDEF_MIME_TYPE } from '../nfc/ndef.js';
import { NtagType, ntagFactoryNdefCapacity, webNfcChunkPayload } from '../nfc/type2.js';
import { NfarFormatError, TOTAL_OVERHEAD } from '../chunk.js';
import type { NdefIO, NdefReading } from './ndef-io.js';
import { uidFromSerialNumber } from './ndef-io.js';
import { CardCapacityError } from '../mifare/card-layout.js';
import { UnidentifiedTagError } from './transport.js';
import type { PresentedTag, Transport } from './transport.js';

export class WebNfcTransport implements Transport {
  readonly name = 'web-nfc';
  private current: NdefReading | null = null;

  /** `tagType` is the user's explicit choice: Web NFC exposes no capability
   *  container, so capacity cannot be discovered from the card. */
  constructor(private readonly io: NdefIO, private readonly tagType: NtagType) {}

  async connect(): Promise<void> {
    // Arm the single scan here rather than lazily on first read: the permission
    // prompt then appears when the user asked for NFC, inside their gesture,
    // and a refusal surfaces at the button instead of inside a scan loop.
    await this.io.start();
  }

  async disconnect(): Promise<void> {
    this.current = null;
    this.io.stop();
  }

  async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    // Clear before awaiting: if this rejects (timeout/abort), the previous
    // tag's reading must not linger in the cache — a later peek/read would
    // then silently answer for a card that is no longer on the reader.
    this.current = null;
    const reading = await this.io.awaitReading(opts);
    // Chrome reports an empty serial for cards (and Android builds) that expose
    // no UID over Web NFC. uidFromSerialNumber('') is a zero-length UID, and the
    // archive/restore loops key their already-written / already-seen sets on
    // that UID: every blank-serial card would collide onto the same key, so
    // cards 2..N would look already-handled and be skipped in silence. Fail the
    // tap instead — and do NOT cache the reading, or peek/read would go on
    // answering for a card we cannot name.
    if (reading.serialNumber === '') {
      throw new UnidentifiedTagError('The card reported no serial number, so it cannot be told apart from other cards');
    }
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
      if (record.recordType !== 'mime' || record.mediaType !== NDEF_MIME_TYPE) continue;
      if (record.data === undefined) continue;
      return record.data;
    }
    return null;
  }

  async peekIsNfar(): Promise<boolean> {
    return this.cachedChunk() !== null;
  }

  async readChunk(): Promise<Uint8Array> {
    // No cached reading means no tag was ever presented, the last tap failed, or
    // a write invalidated the cache — in none of those did we look at a card and
    // find it non-NFAR, which is the only thing NfarFormatError may claim.
    if (this.current === null) {
      throw new UnidentifiedTagError('No tag is present — tap a card, then read');
    }
    const bytes = this.cachedChunk();
    if (bytes === null) throw new NfarFormatError('This tag holds no NFAR NDEF data');
    return bytes;
  }

  async writeChunk(bytes: Uint8Array): Promise<void> {
    const max = webNfcChunkPayload(this.tagType);
    if (bytes.length > TOTAL_OVERHEAD + max) {
      throw new CardCapacityError(
        `Chunk ${bytes.length} B exceeds ${this.tagType}'s ${max} B max NFAR payload ` +
        `(${ntagFactoryNdefCapacity(this.tagType)} B factory NDEF area)`,
      );
    }
    await this.io.write([{ recordType: 'mime', mediaType: NDEF_MIME_TYPE, data: bytes }]);
    // Invalidate rather than re-populate from `bytes`: re-caching our own
    // write buffer would only "verify" that we can read back what we just
    // held in memory, not what actually landed on the tag.
    this.current = null;
  }
}
