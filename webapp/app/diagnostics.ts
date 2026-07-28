/**
 * Card diagnostics — SDK-free and DOM-free so it can be unit-tested.
 *
 * Runs a manual ISO/IEC 14443-A anticollision (7-bit WUPA, then anticollision
 * CL1) via a raw-frame transceiver, WITHOUT the reader firmware's BCC check, so
 * we can read a card's UID even when the firmware rejects it with "HF tag uid
 * bcc error". The BCC (Block Check Character) of a 4-byte UID must equal
 * UID0 ^ UID1 ^ UID2 ^ UID3; a mismatch means a malformed block-0 UID, typical
 * of UID-writable "magic" cards.
 */

/** Sends one raw NfcA frame and returns the tag response bytes. */
export interface RawAntiColl {
  transceive(
    data: number[],
    opts?: { dataBitLength?: number; activateRfField?: boolean; keepRfField?: boolean },
  ): Promise<Uint8Array>;
}

export interface CardDiagnosis {
  /** ATQA (answer to request), 2 bytes. */
  atqa: Uint8Array;
  /** The 4 UID bytes returned in cascade level 1 (starts with 0x88 for 7-byte UIDs). */
  uidCl1: Uint8Array;
  /** BCC byte the card actually returned. */
  bccReturned: number;
  /** BCC we compute from uidCl1. */
  bccComputed: number;
  /** Whether the card's BCC is self-consistent (false ⇒ malformed, e.g. a magic card). */
  bccValid: boolean;
  /** True when uidCl1[0] === 0x88 — a cascade tag, i.e. a 7-byte UID, not a 4-byte Classic 1K. */
  isCascade: boolean;
}

export async function diagnoseCard(dev: RawAntiColl): Promise<CardDiagnosis> {
  // 7-bit WUPA (0x52) wakes any tag in the field and returns its ATQA.
  const atqa = await dev.transceive([0x52], { dataBitLength: 7, activateRfField: true, keepRfField: true });
  // Anticollision CL1 (0x93 0x20) returns 4 UID bytes + 1 BCC byte, with no CRC.
  const ac = await dev.transceive([0x93, 0x20], { keepRfField: false });
  if (ac.length < 5) {
    throw new Error(`Anticollision returned ${ac.length} bytes, expected 5 (UID + BCC)`);
  }
  const uidCl1 = ac.slice(0, 4);
  const bccReturned = ac[4]!;
  const bccComputed = (uidCl1[0]! ^ uidCl1[1]! ^ uidCl1[2]! ^ uidCl1[3]!) & 0xff;
  return {
    atqa,
    uidCl1,
    bccReturned,
    bccComputed,
    bccValid: bccReturned === bccComputed,
    isCascade: uidCl1[0] === 0x88,
  };
}
