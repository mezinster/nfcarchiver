/** Maps a caught error to a plain-language, user-facing message. */
import { CardAuthError, WriteVerifyError, TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';
import { DecryptionError } from '../../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../controller.js';
import { NdefFormatError } from '../../src/nfc/ndef.js';

export function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return 'Card keys are not factory defaults — this card cannot be used.';
  if (e instanceof WriteVerifyError) return 'Write verification failed — move the card closer and retry.';
  if (e instanceof CardCapacityError) return 'A chunk is too large for a 1K card (internal error).';
  if (e instanceof TagTimeoutError) return 'No card detected — tap a card on the reader.';
  if (e instanceof NfarFormatError) return 'This card holds no NFAR archive data.';
  if (e instanceof OverwriteRequiredError) return 'This card already holds data.';
  if (e instanceof PasswordRequiredError) return 'This archive is encrypted — enter a password.';
  if (e instanceof DecryptionError) return 'Wrong password.';
  if (e instanceof UnsupportedTagError) return 'Unsupported tag — use a Mifare Classic 1K or NTAG213/215/216.';
  if (e instanceof NdefFormatError) return 'This tag holds no NFAR NDEF data.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}
