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
  ArchiveController, RestoreController, OverwriteRequiredError, PasswordRequiredError, NfarFormatError,
  type DetectedArchive,
} from './controller.js';
import { estimateCardCount } from './estimate.js';
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
  if (e instanceof DecryptionError) return 'Wrong password.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}

let transport: ChameleonBleTransport | null = null;
let ultra: ChameleonUltra | null = null;

const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

let fileBytes: Uint8Array | null = null;
let fileName = '';

/** Current archive source: the picked file, else the textarea (as text_note.txt). */
function currentSource(): { data: Uint8Array; fileName: string } | null {
  if (fileBytes) return { data: fileBytes, fileName };
  const text = ($('text') as HTMLTextAreaElement).value;
  if (text.length > 0) return { data: new TextEncoder().encode(text), fileName: 'text_note.txt' };
  return null;
}

let counterTimer: ReturnType<typeof setTimeout> | undefined;
function scheduleCounter(): void {
  clearTimeout(counterTimer);
  counterTimer = setTimeout(updateCounter, 200);
}
async function updateCounter(): Promise<void> {
  const src = currentSource();
  const el = $('cardcount');
  if (!src) { el.textContent = ''; return; }
  const compress = ($('compress') as HTMLInputElement).checked;
  const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
  const n = await estimateCardCount(src.data, src.fileName, { compress, encrypted });
  el.textContent = `≈ ${n} card(s)`;
}

$('file').addEventListener('change', async () => {
  const f = ($('file') as HTMLInputElement).files?.[0];
  fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
  fileName = f?.name ?? '';
  updateCounter();
});
for (const id of ['text', 'compress', 'apass']) $(id).addEventListener('input', scheduleCounter);

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
    ($('scan') as HTMLButtonElement).disabled = false;
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
  const src = currentSource();
  if (!src) { setStatus('Pick a file or type some text first.'); return; }
  const compress = ($('compress') as HTMLInputElement).checked;
  const pass = ($('apass') as HTMLInputElement).value;
  const ctrl = new ArchiveController(transport);
  const renderArchive = (written: number, total: number, done: boolean) => {
    showProgress(
      done ? `✓ ${written} of ${total} cards written & verified` : `✓ ${written} of ${total} written & verified — tap the next card`,
      written, total,
    );
    setStatus(done ? `Done — wrote and verified ${written} card(s).` : `Tap card ${written + 1} of ${total} on the reader…`);
  };
  try {
    const total = await ctrl.prepare({ data: src.data, fileName: src.fileName, compress, password: pass || undefined });
    renderArchive(0, total, false);
    let done = false;
    while (!done) {
      try {
        const res = await ctrl.writeNextCard();
        done = res.done;
        renderArchive(res.progress.written, total, done);
      } catch (e) {
        if (e instanceof TagTimeoutError) { setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
        if (e instanceof OverwriteRequiredError) {
          if (confirm('This card already holds data. Overwrite it?')) {
            const res = await ctrl.writeNextCard(undefined, true);
            done = res.done;
            renderArchive(res.progress.written, total, done);
          } else { setStatus('Skipped. Tap a different card…'); }
        } else { throw e; }
      }
    }
  } catch (e) {
    hideProgress();
    setStatus(humanError(e));
  }
});

let scanAbort: AbortController | null = null;

function renderArchives(list: DetectedArchive[], onPick: (id: string) => void): void {
  const container = $('archives');
  container.innerHTML = '';
  for (const a of list) {
    const row = document.createElement('div');
    row.className = 'arch';
    const label = document.createElement('span');
    label.textContent = `Archive ${a.shortId}…  ${a.isEncrypted ? '🔒 encrypted' : 'unencrypted'}  ·  ${a.received} / ${a.totalChunks} card(s)${a.complete ? ' ✓' : ''}`;
    const btn = document.createElement('button');
    btn.textContent = 'Restore';
    btn.disabled = !a.complete;
    btn.addEventListener('click', () => onPick(a.archiveId));
    row.append(label, btn);
    container.appendChild(row);
  }
}

$('scan').addEventListener('click', async () => {
  if (!transport) return;
  const ctrl = new RestoreController(transport);
  scanAbort = new AbortController();
  let pickedId: string | null = null;
  ($('scan') as HTMLButtonElement).disabled = true;
  ($('stop-scan') as HTMLButtonElement).disabled = false;
  setStatus('Scanning — tap cards on the reader…');
  const onPick = (id: string) => { pickedId = id; scanAbort?.abort(); };

  try {
    for (;;) {
      try {
        const list = await ctrl.scanNextCard(scanAbort.signal);
        renderArchives(list, onPick);
        setStatus(`Detected ${list.length} archive(s). Tap more cards, or Restore a complete one.`);
      } catch (e) {
        if (e instanceof TagTimeoutError) continue;
        if (e instanceof DOMException && e.name === 'AbortError') break;
        throw e;
      }
    }
  } catch (e) {
    setStatus(humanError(e));
  } finally {
    ($('stop-scan') as HTMLButtonElement).disabled = true;
    ($('scan') as HTMLButtonElement).disabled = false;
  }

  if (!pickedId) { setStatus('Stopped scanning.'); return; }

  try {
    let pw: string | undefined;
    let result: { data: Uint8Array; fileName: string | null } | undefined;
    for (let attempt = 0; attempt < 5; attempt++) {
      try { result = await ctrl.restore(pickedId, pw); break; }
      catch (e) {
        if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
          const entered = prompt(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:') ?? undefined;
          if (entered === undefined) { setStatus('Cancelled.'); return; }
          pw = entered; continue;
        }
        throw e;
      }
    }
    if (!result) { setStatus('Too many failed password attempts.'); return; }
    const name = result.fileName ?? (($('fname') as HTMLInputElement).value || 'restored.bin');
    if (result.fileName) ($('fname') as HTMLInputElement).value = result.fileName;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([result.data as BlobPart]));
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
    setStatus(`Restored ${result.data.length} bytes → ${name}.`);
  } catch (e) {
    setStatus(humanError(e));
  }
});

$('stop-scan').addEventListener('click', () => scanAbort?.abort());
