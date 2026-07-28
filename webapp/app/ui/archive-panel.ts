/** Archive tab: file/text source, live card counter, write-and-verify with progress. */
import { ArchiveController, OverwriteRequiredError } from '../controller.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { estimateCardCount } from '../estimate.js';
import { NtagType, ntagChunkPayloadSize } from '../../src/nfc/type2.js';
import { CARD_PAYLOAD_SIZE } from '../../src/mifare/card-layout.js';
import { currentTransport, onConnectionChange } from './device.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function selectedPayloadSize(): number {
  const v = ($('target-tag') as HTMLSelectElement).value;
  if (v === 'auto') return CARD_PAYLOAD_SIZE; // nominal preview size; the real card decides on tap
  if (v === 'NTAG213') return ntagChunkPayloadSize(NtagType.NTAG213);
  if (v === 'NTAG215') return ntagChunkPayloadSize(NtagType.NTAG215);
  if (v === 'NTAG216') return ntagChunkPayloadSize(NtagType.NTAG216);
  return Number(v); // "720" for Mifare Classic 1K
}

export function initArchivePanel(): void {
  const setStatus = (msg: string) => { $('archive-status').textContent = msg; };
  const bar = $('archive-bar') as HTMLProgressElement;
  const showProgress = (label: string, value: number | null, max: number) => {
    $('archive-progress-row').hidden = false;
    bar.max = max;
    if (value === null) bar.removeAttribute('value'); else bar.value = value;
    $('archive-progress-label').textContent = label;
  };
  const hideProgress = () => { $('archive-progress-row').hidden = true; };

  let fileBytes: Uint8Array | null = null;
  let fileName = '';
  const currentSource = (): { data: Uint8Array; fileName: string } | null => {
    if (fileBytes) return { data: fileBytes, fileName };
    const text = ($('text') as HTMLTextAreaElement).value;
    if (text.length > 0) return { data: new TextEncoder().encode(text), fileName: 'text_note.txt' };
    return null;
  };

  let counterTimer: ReturnType<typeof setTimeout> | undefined;
  const updateCounter = async (): Promise<void> => {
    const src = currentSource();
    const el = $('cardcount');
    if (!src) { el.textContent = ''; return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
    const count = await estimateCardCount(src.data, src.fileName, { compress, encrypted, payloadSize: selectedPayloadSize() });
    const isAuto = ($('target-tag') as HTMLSelectElement).value === 'auto';
    el.textContent = `≈ ${count} card(s)${isAuto ? ' (est.) — adapts to the tapped card' : ''}`;
  };
  const scheduleCounter = () => { clearTimeout(counterTimer); counterTimer = setTimeout(updateCounter, 200); };

  $('file').addEventListener('change', async () => {
    const f = ($('file') as HTMLInputElement).files?.[0];
    fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
    fileName = f?.name ?? '';
    updateCounter();
  });
  for (const id of ['text', 'compress', 'apass']) $(id).addEventListener('input', scheduleCounter);
  $('target-tag').addEventListener('change', scheduleCounter);

  onConnectionChange((connected) => {
    ($('archive') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus('Choose a file or type text, then Archive to cards.');
  });

  $('archive').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const src = currentSource();
    if (!src) { setStatus('Pick a file or type some text first.'); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const pass = ($('apass') as HTMLInputElement).value;
    const ctrl = new ArchiveController(transport);
    const render = (written: number, total: number, done: boolean) => {
      showProgress(
        done ? `✓ ${written} of ${total} cards written & verified` : `✓ ${written} of ${total} written & verified — tap the next card`,
        written, total,
      );
      setStatus(done ? `Done — wrote and verified ${written} card(s).` : `Tap card ${written + 1} of ${total} on the reader…`);
    };
    try {
      let total = await ctrl.prepare({ data: src.data, fileName: src.fileName, compress, password: pass || undefined, payloadSize: selectedPayloadSize() });
      render(0, total, false);
      let done = false;
      while (!done) {
        try {
          const res = await ctrl.writeNextCard();
          if (res.rechunkedTo) {
            const orig = total;
            total = res.rechunkedTo.total;
            setStatus(`Card holds ${res.rechunkedTo.payloadSize} B/chunk — writing ${total} card(s) instead of ${orig}.`);
          }
          done = res.done;
          render(res.progress.written, total, done);
        } catch (e) {
          if (e instanceof TagTimeoutError) { setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
          if (e instanceof UnsupportedTagError) { setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); continue; }
          if (e instanceof OverwriteRequiredError) {
            if (confirm('This card already holds data. Overwrite it?')) {
              const res = await ctrl.writeNextCard(undefined, true);
              done = res.done;
              render(res.progress.written, total, done);
            } else { setStatus('Skipped. Tap a different card…'); }
          } else { throw e; }
        }
      }
    } catch (e) {
      hideProgress();
      setStatus(humanError(e));
    }
  });
}
