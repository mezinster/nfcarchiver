/** Archive tab: file/text source, live card counter, write-and-verify with progress. */
import { ArchiveOrchestrator, type ArchiveIO, type OverwriteChoice } from './archive-orchestrator.js';
import type { Transport } from '../../src/transport/transport.js';
import { estimateCardCount } from '../estimate.js';
import { NtagType, ntagChunkPayloadSize } from '../../src/nfc/type2.js';
import { CARD_PAYLOAD_SIZE } from '../../src/mifare/card-layout.js';
import { currentTransport, isConnected, onConnectionChange, setReaderBusy } from './device.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';

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

  // Native <dialog> confirm with three choices. Resolves 'once' | 'all' | 'skip'
  // ('skip' if dismissed via Esc, so an accidental dismiss never overwrites).
  const overwriteDialog = $('overwrite-dialog') as HTMLDialogElement;
  const confirmOverwrite = (): Promise<OverwriteChoice> => new Promise((resolve) => {
    overwriteDialog.returnValue = '';
    overwriteDialog.addEventListener('close', () => {
      const v = overwriteDialog.returnValue;
      resolve(v === 'all' ? 'all' : v === 'once' ? 'once' : 'skip');
    }, { once: true });
    overwriteDialog.showModal();
  });

  let archiving = false;

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
    ($('archive') as HTMLButtonElement).disabled = !connected || archiving;
    if (connected && !archiving) setStatus('Choose a file or type text, then Archive to cards.');
  });

  $('archive').addEventListener('click', async () => {
    if (archiving) return;
    const transport = currentTransport();
    if (!transport) return;
    const src = currentSource();
    if (!src) { setStatus('Pick a file or type some text first.'); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const pass = ($('apass') as HTMLInputElement).value;

    const io: ArchiveIO = {
      setStatus,
      showProgress,
      hideProgress,
      confirmOverwrite,
      isConnected,
      // Resolve with the freshly-built transport the next time we connect.
      awaitReconnect: () => new Promise<Transport>((resolve) => {
        const off = onConnectionChange((connected) => {
          const t = currentTransport();
          if (connected && t) { off(); resolve(t); }
        });
      }),
      log,
    };

    archiving = true;
    setReaderBusy(true);
    ($('archive') as HTMLButtonElement).disabled = true;
    try {
      await new ArchiveOrchestrator(io).run(transport, {
        data: src.data, fileName: src.fileName, compress,
        password: pass || undefined, payloadSize: selectedPayloadSize(),
      });
    } catch (e) {
      hideProgress();
      setStatus(humanError(e));
    } finally {
      setReaderBusy(false);
      archiving = false;
      ($('archive') as HTMLButtonElement).disabled = !isConnected();
    }
  });
}
