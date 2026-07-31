/** Archive tab: file/text source, live card counter, write-and-verify with progress. */
import { ArchiveOrchestrator, type ArchiveIO, type OverwriteChoice } from './archive-orchestrator.js';
import type { Transport } from '../../src/transport/transport.js';
import { estimateCardCount } from '../estimate.js';
import { NtagType, ntagChunkPayloadSize, webNfcChunkPayload } from '../../src/nfc/type2.js';
import { CARD_PAYLOAD_SIZE } from '../../src/mifare/card-layout.js';
import { activeReaderName, currentTransport, isConnected, onConnectionChange } from './device.js';
import { readerLock } from './reader-lock.js';
import { humanError } from './errors.js';
import { t } from '../i18n/index.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function selectedPayloadSize(): number {
  const v = ($('target-tag') as HTMLSelectElement).value;
  const webNfc = activeReaderName() === 'web-nfc';
  if (v === 'auto') return CARD_PAYLOAD_SIZE; // nominal preview size; the real card decides on tap
  // Under Web NFC there is no capability-container tap to re-chunk from, so the
  // estimate must already match the factory CC's usable area (webNfcChunkPayload),
  // not the raw-memory estimate the Chameleon path uses (ntagChunkPayloadSize) —
  // see PR #41 / #48 / #49 for the truncation bug this guards against.
  if (v === 'NTAG213') return webNfc ? webNfcChunkPayload(NtagType.NTAG213) : ntagChunkPayloadSize(NtagType.NTAG213);
  if (v === 'NTAG215') return webNfc ? webNfcChunkPayload(NtagType.NTAG215) : ntagChunkPayloadSize(NtagType.NTAG215);
  if (v === 'NTAG216') return webNfc ? webNfcChunkPayload(NtagType.NTAG216) : ntagChunkPayloadSize(NtagType.NTAG216);
  return Number(v); // "720" for Mifare Classic 1K
}

/** Keeps `#target-tag` sane for the active reader. Web NFC exposes no capability
 *  container, so neither "Auto-detect" (which relies on tapping a real card to
 *  discover capacity) nor Mifare Classic 1K (`selectedNtagType()` in device.ts
 *  has no NTAG mapping for it and falls back to NTAG215 for the transport) is
 *  usable there — disable both options and, if either was selected, fall back
 *  to a concrete NTAG chip. Recomputed on every reader hand-off so both
 *  re-enable when switching back to the Chameleon. Does NOT touch
 *  archive-status itself: that element also carries archive progress/error
 *  text (see the onConnectionChange handler below), and writing here
 *  unconditionally would clobber a message mid-archive if the user swaps
 *  readers while a write is in progress (the Connect/Use-phone-NFC buttons
 *  stay enabled during archiving).
 *
 *  Returns whether it moved the selection — assigning `sel.value` fires no
 *  `change` event, so the caller must drive whatever that event would have. */
function syncTargetTagForReader(): boolean {
  const sel = $('target-tag') as HTMLSelectElement;
  const auto = sel.querySelector<HTMLOptionElement>('option[value="auto"]')!;
  const mifare = sel.querySelector<HTMLOptionElement>('option[value="720"]')!;
  const webNfc = activeReaderName() === 'web-nfc';
  auto.disabled = webNfc;
  mifare.disabled = webNfc;
  if (webNfc && (sel.value === 'auto' || sel.value === '720')) {
    sel.value = 'NTAG215';
    return true;
  }
  return false;
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

  // Whether THIS panel is driving the reader. Previously a private `archiving`
  // boolean; it is now derived from the shared lock so that a running scan
  // blocks a write and vice versa — two loops calling awaitTag() on one reader
  // is what made every card of a 16-card archive fail on 2026-07-31.
  const archivingNow = (): boolean => readerLock.current() === 'archive';

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
    el.textContent = t.cardEstimate(count, isAuto);
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

  const syncArchiveButton = (): void => {
    const owner = readerLock.current();
    const btn = $('archive') as HTMLButtonElement;
    btn.disabled = !isConnected() || owner !== null;
    btn.title = owner !== null && owner !== 'archive' ? t.readerBusyElsewhere : '';
  };
  readerLock.onChange(syncArchiveButton);

  onConnectionChange((connected) => {
    syncArchiveButton();
    // The fallback changes the basis of the card-count estimate (720 B/chunk ->
    // NTAG215's), and a programmatic `sel.value = …` fires no change event, so
    // the counter would otherwise keep showing the old figure until the first tap.
    if (syncTargetTagForReader()) scheduleCounter();
    // Guarded the same way the pre-existing archiveReady write was: while a
    // write is in progress, this element carries live progress/error text
    // (see ArchiveOrchestrator's io.setStatus calls) that a reader hand-off
    // must not stomp.
    if (connected && !archivingNow()) {
      setStatus(activeReaderName() === 'web-nfc' ? t.autoDetectNeedsChameleon : t.archiveReady);
    }
  });

  $('archive').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const src = currentSource();
    // Acquire only after the cheap rejections, or an early return would leak
    // the lock and wedge the reader for every other panel.
    if (!src) { setStatus(t.archivePickFirst); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const pass = ($('apass') as HTMLInputElement).value;

    const io: ArchiveIO = {
      setStatus,
      showProgress,
      hideProgress,
      confirmOverwrite,
      isConnected,
      activeTransport: currentTransport,
      // Resolve with the freshly-built transport the next time we connect — or
      // right away if one is already live. A reader hand-off (Connect, Use
      // phone NFC, or a target-tag change under phone NFC) installs the new
      // transport before the write loop gets to look, so waiting for a further
      // connection event would wait forever.
      awaitReconnect: () => new Promise<Transport>((resolve) => {
        const live = currentTransport();
        if (isConnected() && live) { resolve(live); return; }
        const off = onConnectionChange(() => {
          const next = currentTransport();
          if (isConnected() && next) { off(); resolve(next); }
        });
      }),
      log,
    };

    if (!readerLock.acquire('archive')) { setStatus(t.readerBusyElsewhere); return; }
    try {
      await new ArchiveOrchestrator(io).run(transport, {
        data: src.data, fileName: src.fileName, compress,
        password: pass || undefined, payloadSize: selectedPayloadSize(),
      });
    } catch (e) {
      hideProgress();
      setStatus(humanError(e));
    } finally {
      readerLock.release('archive');
    }
  });
}
