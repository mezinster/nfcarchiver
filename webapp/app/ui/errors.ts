/** Maps a caught error to a plain-language, user-facing message. The single
 *  translation seam for everything src/ throws — src/ itself stays English. */
import { CardAuthError, CardReadError, WriteVerifyError, TagTimeoutError, UnsupportedTagError, UnidentifiedTagError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';
import { DecryptionError } from '../../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../controller.js';
import { NdefFormatError } from '../../src/nfc/ndef.js';
import { t } from '../i18n/index.js';

export function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return t.errCardAuth;
  if (e instanceof CardReadError) return t.errCardRead;
  if (e instanceof WriteVerifyError) return t.errWriteVerify;
  if (e instanceof CardCapacityError) return t.errCardCapacity;
  if (e instanceof TagTimeoutError) return t.errTagTimeout;
  if (e instanceof NfarFormatError) return t.errNfarFormat;
  if (e instanceof OverwriteRequiredError) return t.errOverwriteRequired;
  if (e instanceof PasswordRequiredError) return t.errPasswordRequired;
  if (e instanceof DecryptionError) return t.errWrongPassword;
  if (e instanceof UnsupportedTagError) return t.errUnsupportedTag;
  if (e instanceof UnidentifiedTagError) return t.errUnidentifiedTag;
  if (e instanceof NdefFormatError) return t.errNdefFormat;
  if (e instanceof DOMException && e.name === 'AbortError') return t.cancelled;
  return e instanceof Error ? e.message : String(e);
}
