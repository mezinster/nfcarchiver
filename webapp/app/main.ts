/**
 * DOM glue only: constructs the real transport, drives the controllers, and
 * renders progress/errors. No business logic lives here (that is controller.ts).
 */

import { ChameleonUltra, Buffer } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../src/transport/sdk-chameleon-device.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { diagnoseCard, type RawAntiColl } from './diagnostics.js';
import {
  ArchiveController, RestoreController, OverwriteRequiredError, PasswordRequiredError, WrongArchiveError, NfarFormatError,
} from './controller.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';
import { DecryptionError } from '../src/crypto.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = $('status');
const setStatus = (msg: string) => { status.textContent = msg; };

const progressRow = $('progress-row');
const bar = $('bar') as HTMLProgressElement;
const progressLabel = $('progress-label');

/** Show the bar. Pass value=null for an indeterminate (unknown-total) state. */
function showProgress(label: string, value: number | null, max: number): void {
  progressRow.hidden = false;
  bar.max = max;
  if (value === null) bar.removeAttribute('value'); // indeterminate
  else bar.value = value;
  progressLabel.textContent = label;
}
function hideProgress(): void {
  progressRow.hidden = true;
}

function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return 'Card keys are not factory defaults — this card cannot be used.';
  if (e instanceof WriteVerifyError) return 'Write verification failed — move the card closer and retry.';
  if (e instanceof CardCapacityError) return 'A chunk is too large for a 1K card (internal error).';
  if (e instanceof TagTimeoutError) return 'No card detected — tap a card on the reader.';
  if (e instanceof NfarFormatError) return 'This card holds no NFAR archive data.';
  if (e instanceof OverwriteRequiredError) return 'This card already holds data.';
  if (e instanceof PasswordRequiredError) return 'This archive is encrypted — enter a password.';
  if (e instanceof WrongArchiveError) return 'This card belongs to a different archive.';
  if (e instanceof DecryptionError) return 'Wrong password.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}

let transport: ChameleonBleTransport | null = null;
let ultra: ChameleonUltra | null = null;

const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

$('connect').addEventListener('click', async () => {
  try {
    ultra = new ChameleonUltra();
    // use() is async (the adapter's install() runs availability checks etc.);
    // it MUST be awaited before connect(), or this.port is still undefined.
    await ultra.use(new WebbleAdapter());
    transport = new ChameleonBleTransport(new SdkChameleonDevice(ultra));
    await transport.connect();
    $('conn').textContent = 'connected';
    ($('archive') as HTMLButtonElement).disabled = false;
    ($('restore') as HTMLButtonElement).disabled = false;
    ($('diagnose') as HTMLButtonElement).disabled = false;
    setStatus('Connected. Choose a file to archive, or restore from cards.');
  } catch (e) {
    setStatus(humanError(e));
  }
});

// Diagnostic: read the raw UID + BCC of the card on the reader, bypassing the
// firmware BCC check, to explain "HF tag uid bcc error" failures.
$('diagnose').addEventListener('click', async () => {
  if (!ultra) return;
  const dev = ultra;
  const raw: RawAntiColl = {
    async transceive(data, opts) {
      const resp = await dev.cmdHf14aRaw({
        data: Buffer.from(data),
        dataBitLength: opts?.dataBitLength ?? 0,
        activateRfField: opts?.activateRfField ?? false,
        keepRfField: opts?.keepRfField ?? false,
        checkResponseCrc: false,
        waitResponse: true,
      });
      return new Uint8Array(resp);
    },
  };
  setStatus('Hold the card on the reader…');
  try {
    const d = await diagnoseCard(raw);
    const verdict = d.isCascade
      ? '7-byte UID (cascade tag) — this is not a 4-byte Mifare Classic 1K.'
      : d.bccValid
        ? 'BCC OK — this card should work; the earlier error was likely transient positioning.'
        : 'BCC MISMATCH — malformed block-0 UID (a UID-writable "magic" card). Rewrite block 0 with a correct BCC, or use a standard Classic 1K.';
    setStatus(
      `ATQA: ${hex(d.atqa)}\n` +
      `UID (CL1): ${hex(d.uidCl1)}\n` +
      `BCC returned: 0x${d.bccReturned.toString(16).padStart(2, '0')}  computed: 0x${d.bccComputed.toString(16).padStart(2, '0')}\n` +
      verdict,
    );
  } catch (e) {
    setStatus(`Diagnose failed: ${humanError(e)} (hold a card steady on the reader and retry)`);
  }
});

$('archive').addEventListener('click', async () => {
  if (!transport) return;
  const file = ($('file') as HTMLInputElement).files?.[0];
  if (!file) { setStatus('Pick a file first.'); return; }
  const data = new Uint8Array(await file.arrayBuffer());
  const compress = ($('compress') as HTMLInputElement).checked;
  const pass = ($('apass') as HTMLInputElement).value;
  const ctrl = new ArchiveController(transport);
  const renderArchive = (written: number, total: number, done: boolean) => {
    showProgress(
      done ? `✓ ${written} of ${total} cards written & verified` : `✓ ${written} of ${total} written & verified — tap the next card`,
      written,
      total,
    );
    setStatus(done ? `Done — wrote and verified ${written} card(s).` : `Tap card ${written + 1} of ${total} on the reader…`);
  };
  try {
    const total = await ctrl.prepare({ data, compress, password: pass || undefined });
    renderArchive(0, total, false);
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.writeNextCard();
        done = res.done;
        renderArchive(res.progress.written, total, done);
      } catch (e) {
        if (e instanceof TagTimeoutError) {
          setStatus('No card detected — tap a card on the reader (hold it a few mm off)…');
          continue;
        }
        if (e instanceof OverwriteRequiredError) {
          if (confirm('This card already holds data. Overwrite it?')) {
            const res = await ctrl.writeNextCard(undefined, true);
            done = res.done;
            renderArchive(res.progress.written, total, done);
          } else {
            setStatus('Skipped. Tap a different card…');
          }
        } else { throw e; }
      }
    }
  } catch (e) {
    hideProgress();
    setStatus(humanError(e));
  }
});

$('restore').addEventListener('click', async () => {
  if (!transport) return;
  const ctrl = new RestoreController(transport);
  try {
    showProgress('Scanning — tap the first card…', null, 1); // total unknown until first card
    setStatus('Tap the first card on the reader…');
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.scanNextCard();
        done = res.done;
        if (res.total === null) {
          showProgress(`Scanning — ${res.collected} collected…`, null, 1);
        } else {
          showProgress(
            done ? `All ${res.total} cards scanned` : `${res.collected} of ${res.total} cards scanned — tap the next card`,
            res.collected,
            res.total,
          );
        }
        setStatus(done ? 'All cards scanned. Assembling…' : `Collected ${res.collected}${res.total ? ` of ${res.total}` : ''}. Tap the next card…`);
      } catch (e) {
        if (e instanceof TagTimeoutError) {
          setStatus('No card detected — tap a card on the reader (hold it a few mm off)…');
          continue;
        }
        throw e;
      }
    }
    let out: Uint8Array | undefined;
    let pw: string | undefined;
    const maxPasswordAttempts = 5;
    for (let attempt = 0; attempt < maxPasswordAttempts; attempt++) {
      try {
        out = await ctrl.finish(pw);
        break;
      } catch (e) {
        if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
          const promptMsg = e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:';
          const entered = prompt(promptMsg) ?? undefined;
          if (entered === undefined) { setStatus('Cancelled.'); return; }
          pw = entered;
          continue;
        }
        throw e;
      }
    }
    if (out === undefined) {
      setStatus('Too many failed password attempts.');
      return;
    }
    const name = ($('fname') as HTMLInputElement).value || 'restored.bin';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([out as BlobPart]));
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
    setStatus(`Restored ${out.length} bytes → ${name}.`);
  } catch (e) {
    hideProgress();
    setStatus(humanError(e));
  }
});
