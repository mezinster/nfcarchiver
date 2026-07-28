/**
 * A Transport moves one serialized NFAR chunk to/from the physical card
 * currently presented to a reader. v2: promise-based tag arrival, UID identity,
 * and write-then-verify semantics in writeChunk implementations.
 */

export interface PresentedTag {
  uid: Uint8Array;
  capacityBytes: number;
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
