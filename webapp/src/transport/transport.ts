/**
 * A Transport moves one serialized NFAR chunk to/from the physical card
 * currently presented to a reader. v2: promise-based tag arrival, UID identity,
 * and write-then-verify semantics in writeChunk implementations.
 */

export interface PresentedTag {
  uid: Uint8Array;
  capacityBytes: number;   // raw user memory (informational)
  maxChunkPayload: number; // max NFAR chunk-payload this card holds
}

export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Resolves when a tag enters the field. Rejects TagTimeoutError or AbortError. */
  awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag>;
  /** Whether the current tag holds an NFAR chunk. */
  peekIsNfar(): Promise<boolean>;
  /** Read the chunk from the current tag. Throws NfarFormatError on a non-NFAR card. */
  readChunk(): Promise<Uint8Array>;
  /** Write the chunk to the current tag, then read back and verify. */
  writeChunk(bytes: Uint8Array): Promise<void>;
}

export class CardAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardAuthError';
  }
}

/**
 * A block/page read came back short — the reader returned fewer bytes than the
 * card layer asked for without reporting an error, which the Chameleon does on
 * marginal coupling. Such a read says NOTHING about what the card holds, so it
 * must never be mistaken for a non-NFAR verdict: it is transient and a re-tap
 * (or an immediate retry) can succeed.
 */
export class CardReadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CardReadError';
  }
}

export class WriteVerifyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WriteVerifyError';
  }
}

export class TagTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TagTimeoutError';
  }
}

export class UnsupportedTagError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnsupportedTagError';
  }
}

/**
 * There is no usable tag: either none has been presented, or one was presented
 * whose identity the reader could not establish (Web NFC hands us an empty
 * serial number on some cards and some Android builds).
 *
 * Identity is not cosmetic — the archive and restore loops key their
 * already-written / already-seen sets on the UID, so an unidentifiable card
 * must fail loudly rather than be given a substitute UID. A minted-empty UID
 * collides every such card onto one key, and a random one would let the same
 * card be written twice. Both are silent data loss; a re-tap prompt is not.
 */
export class UnidentifiedTagError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnidentifiedTagError';
  }
}
