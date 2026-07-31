/**
 * Seam over the Web NFC API. `NDEFReader` exists only in Chrome on Android, and
 * `src/` must import cleanly under `node --test`, so nothing here touches a
 * browser global — the real implementation lives in app/ui/browser-ndef-io.ts.
 */

export interface NdefRecordInit {
  recordType: string;
  mediaType?: string;
  data?: Uint8Array;
}

export interface NdefReadRecord {
  recordType: string;
  mediaType?: string;
  data?: Uint8Array;
}

export interface NdefReading {
  /** Colon-separated hex, e.g. "04:7b:cd:a4:82:26:81". May be empty — Chrome
   *  reports no serial for some cards and some Android builds. WebNfcTransport
   *  rejects that tap (UnidentifiedTagError) rather than working with a card it
   *  cannot tell apart from any other. */
  serialNumber: string;
  records: NdefReadRecord[];
}

export interface NdefIO {
  /** Resolves with the first tag presented. Rejects on timeout or abort. */
  awaitReading(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<NdefReading>;
  /** Write to the tag currently in the field. */
  write(records: NdefRecordInit[]): Promise<void>;
  /** Stop any active scan. */
  stop(): void;
}

/** Chrome reports the UID as colon-separated hex; the rest of the app uses bytes. */
export function uidFromSerialNumber(serial: string): Uint8Array {
  if (serial === '') return new Uint8Array(0);
  const segments = serial.split(':');
  const bytes: number[] = [];
  for (const seg of segments) {
    if (!/^[0-9a-fA-F]{1,2}$/.test(seg)) {
      throw new Error(`Invalid segment in serial "${serial}": "${seg}"`);
    }
    bytes.push(parseInt(seg, 16));
  }
  return Uint8Array.from(bytes);
}
