/**
 * DOM glue only: constructs the real transport, drives the controllers, and
 * renders progress/errors. No business logic lives here (that is controller.ts).
 */

import { ChameleonUltra } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../src/transport/sdk-chameleon-device.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import {
  ArchiveController, RestoreController, OverwriteRequiredError, PasswordRequiredError, NfarFormatError,
} from './controller.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = $('status');
const setStatus = (msg: string) => { status.textContent = msg; };

function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return 'Card keys are not factory defaults — this card cannot be used.';
  if (e instanceof WriteVerifyError) return 'Write verification failed — move the card closer and retry.';
  if (e instanceof CardCapacityError) return 'A chunk is too large for a 1K card (internal error).';
  if (e instanceof TagTimeoutError) return 'No card detected — tap a card on the reader.';
  if (e instanceof NfarFormatError) return 'This card holds no NFAR archive data.';
  if (e instanceof OverwriteRequiredError) return 'This card already holds data.';
  if (e instanceof PasswordRequiredError) return 'This archive is encrypted — enter a password.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}

let transport: ChameleonBleTransport | null = null;

$('connect').addEventListener('click', async () => {
  try {
    const ultra = new ChameleonUltra();
    ultra.use(new WebbleAdapter());
    transport = new ChameleonBleTransport(new SdkChameleonDevice(ultra));
    await transport.connect();
    $('conn').textContent = 'connected';
    ($('archive') as HTMLButtonElement).disabled = false;
    ($('restore') as HTMLButtonElement).disabled = false;
    setStatus('Connected. Choose a file to archive, or restore from cards.');
  } catch (e) {
    setStatus(humanError(e));
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
  try {
    const total = await ctrl.prepare({ data, compress, password: pass || undefined });
    setStatus(`Need ${total} card(s). Tap card 1 of ${total}…`);
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.writeNextCard();
        done = res.done;
        setStatus(done ? `Done — wrote ${res.progress.written} card(s).` : `Wrote ${res.progress.written} of ${total}. Tap the next card…`);
      } catch (e) {
        if (e instanceof OverwriteRequiredError) {
          if (confirm('This card already holds data. Overwrite it?')) {
            const res = await ctrl.writeNextCard(undefined, true);
            done = res.done;
            setStatus(done ? `Done — wrote ${res.progress.written} card(s).` : `Wrote ${res.progress.written} of ${total}. Tap the next card…`);
          } else {
            setStatus('Skipped. Tap a different card…');
          }
        } else { throw e; }
      }
    }
  } catch (e) {
    setStatus(humanError(e));
  }
});

$('restore').addEventListener('click', async () => {
  if (!transport) return;
  const ctrl = new RestoreController(transport);
  try {
    setStatus('Tap the first card…');
    let done = false;
    while (!done) {
      const res = await ctrl.scanNextCard();
      done = res.done;
      setStatus(done ? 'All cards scanned. Assembling…' : `Collected ${res.collected}${res.total ? ` of ${res.total}` : ''}. Tap the next card…`);
    }
    let out: Uint8Array;
    try {
      out = await ctrl.finish();
    } catch (e) {
      if (e instanceof PasswordRequiredError) {
        const pw = prompt('This archive is encrypted. Enter password:') ?? undefined;
        out = await ctrl.finish(pw);
      } else { throw e; }
    }
    const name = ($('fname') as HTMLInputElement).value || 'restored.bin';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([out as BlobPart]));
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
    setStatus(`Restored ${out.length} bytes → ${name}.`);
  } catch (e) {
    setStatus(humanError(e));
  }
});
