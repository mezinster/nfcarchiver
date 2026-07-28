/** Restore tab: scan a pile of cards, detect archives, pick a complete one to restore. */
import { RestoreController, PasswordRequiredError, type DetectedArchive } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { DecryptionError } from '../../src/crypto.js';
import { currentTransport, onConnectionChange } from './device.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

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

export function initRestorePanel(): void {
  const setStatus = (msg: string) => { $('restore-status').textContent = msg; };
  let scanAbort: AbortController | null = null;

  onConnectionChange((connected) => {
    ($('scan') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus('Scan a pile of cards to detect archives.');
  });

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const ctrl = new RestoreController(transport);
    scanAbort = new AbortController();
    let pickedId: string | null = null;
    ($('scan') as HTMLButtonElement).disabled = true;
    ($('stop-scan') as HTMLButtonElement).disabled = false;
    setStatus('Scanning — tap cards on the reader…');
    const onPick = (id: string) => {
      pickedId = id;
      $('archives').querySelectorAll('button').forEach((b) => { (b as HTMLButtonElement).disabled = true; });
      scanAbort?.abort();
    };

    try {
      try {
        for (;;) {
          try {
            const list = await ctrl.scanNextCard(scanAbort.signal);
            renderArchives(list, onPick);
            setStatus(`Detected ${list.length} archive(s). Tap more cards, or Restore a complete one.`);
          } catch (e) {
            // Only an abort (Stop / Restore pick) ends the scan; every per-tap
            // failure just skips that card so the session — and its Restore
            // buttons — stay alive.
            if (e instanceof DOMException && e.name === 'AbortError') break;
            if (e instanceof TagTimeoutError) continue;
            if (e instanceof UnsupportedTagError) { setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); continue; }
            setStatus(`Skipped a card: ${humanError(e)}`);
            continue;
          }
        }
      } catch (e) {
        setStatus(humanError(e));
        return;
      }

      if (!pickedId) { setStatus('Stopped scanning.'); return; }
      const chosenId = pickedId;

      try {
        let pw: string | undefined;
        let result: { data: Uint8Array; fileName: string | null } | undefined;
        for (let attempt = 0; attempt < 5; attempt++) {
          try { result = await ctrl.restore(chosenId, pw); break; }
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
    } finally {
      ($('stop-scan') as HTMLButtonElement).disabled = true;
      ($('scan') as HTMLButtonElement).disabled = false;
    }
  });

  $('stop-scan').addEventListener('click', () => scanAbort?.abort());
}
