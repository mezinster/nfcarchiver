/** Archive tab: file/text source, live card counter, write-and-verify with progress. */
import { ArchiveOrchestrator, type ArchiveIO, type ArchiveOutcome, type OverwriteChoice } from './archive-orchestrator.js';
import { renderSlots } from './stage-view.js';
import type { Transport } from '../../src/transport/transport.js';
import { estimateCardCount } from '../estimate.js';
import { NtagType, ntagChunkPayloadSize, webNfcChunkPayload } from '../../src/nfc/type2.js';
import { CARD_PAYLOAD_SIZE } from '../../src/mifare/card-layout.js';
import { activeReaderName, currentTransport, isConnected, onConnectionChange } from './device.js';
import { readerLock } from './reader-lock.js';
import { humanError } from './errors.js';
import { t, onLocaleChange } from '../i18n/index.js';
import { pickSource, type SourceMode } from '../source.js';
import { humanSize } from './files-view.js';
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
  const setStatus = (msg: string, tone: 'info' | 'error' = 'info'): void => {
    const el = $('archive-status');
    el.textContent = msg;
    if (tone === 'error') el.setAttribute('data-tone', 'error');
    else el.removeAttribute('data-tone');
    $('stage-headline').textContent = msg;
  };
  const bar = $('archive-bar') as HTMLProgressElement;
  let slotsWritten = 0;
  let slotsTotal = 0;
  let slotWarning = false;
  const drawSlots = (): void => {
    renderSlots($('archive-slots'), slotsWritten, slotsTotal, { warning: slotWarning });
  };
  const showProgress = (label: string, value: number | null, max: number): void => {
    $('archive-progress').hidden = false;
    bar.max = max;
    if (value === null) bar.removeAttribute('value'); else bar.value = value;
    const done = value !== null && value >= max;
    // The orchestrator's label is a sentence; the stage shows "Card n of N"
    // while writing and keeps the sentence ("✓ 3 of 3 … verified") once done.
    $('archive-progress-label').textContent = done ? label : t.cardOfTotal(Math.min((value ?? 0) + 1, max), max);
    $('archive-progress-pct').textContent = value === null || max === 0 ? '' : `${Math.round((value / max) * 100)}%`;
    // max changes mid-write when Auto-detect re-chunks, so redraw on every call.
    slotsWritten = value ?? 0;
    slotsTotal = max;
    drawSlots();
  };
  const hideProgress = (): void => { $('archive-progress').hidden = true; };

  // Native <dialog> confirm with three choices. Resolves 'once' | 'all' | 'skip'
  // ('skip' if dismissed via Esc, so an accidental dismiss never overwrites).
  const overwriteDialog = $('overwrite-dialog') as HTMLDialogElement;
  const confirmOverwrite = (): Promise<OverwriteChoice> => new Promise((resolve) => {
    overwriteDialog.returnValue = '';
    slotWarning = true;
    drawSlots();
    overwriteDialog.addEventListener('close', () => {
      slotWarning = false;
      drawSlots();
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
  let mode: SourceMode = 'file';
  const currentSource = () => pickSource(
    mode,
    fileBytes ? { bytes: fileBytes, name: fileName } : null,
    ($('text') as HTMLTextAreaElement).value,
  );

  let counterTimer: ReturnType<typeof setTimeout> | undefined;
  let estimateGen = 0;
  const updateCounter = async (): Promise<void> => {
    const gen = ++estimateGen;
    const src = currentSource();
    const el = $('cardcount');
    if (!src) { el.replaceChildren(); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
    const count = await estimateCardCount(src.data, src.fileName, { compress, encrypted, payloadSize: selectedPayloadSize() });
    if (gen !== estimateGen) return; // a newer call started while we awaited
    const sel = $('target-tag') as HTMLSelectElement;
    const title = document.createElement('div');
    title.className = 'estimate-title';
    title.textContent = t.cardsNeeded(count);
    const sub = document.createElement('div');
    sub.className = 'estimate-sub';
    sub.textContent = sel.value === 'auto' ? t.estimateAuto : (sel.selectedOptions[0]?.textContent ?? '');
    el.replaceChildren(title, sub);
  };
  const scheduleCounter = () => { clearTimeout(counterTimer); counterTimer = setTimeout(updateCounter, 200); };

  $('file').addEventListener('change', async () => {
    const f = ($('file') as HTMLInputElement).files?.[0];
    fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
    fileName = f?.name ?? '';
    $('file-pick').toggleAttribute('data-has-file', f !== undefined);
    $('file-name').textContent = fileName;
    $('file-size').textContent = f ? humanSize(f.size) : '';
    void updateCounter();
  });

  const setMode = (m: SourceMode): void => {
    mode = m;
    $('source-file-btn').setAttribute('aria-pressed', String(m === 'file'));
    $('source-text-btn').setAttribute('aria-pressed', String(m === 'text'));
    $('file-pick').hidden = m !== 'file';
    $('text-source').hidden = m !== 'text';
    void updateCounter();
  };
  $('source-file-btn').addEventListener('click', () => setMode('file'));
  $('source-text-btn').addEventListener('click', () => setMode('text'));
  // The estimate's words come from `t`; re-render them on a language switch.
  onLocaleChange(() => { void updateCounter(); });
  for (const id of ['text', 'compress', 'apass']) $(id).addEventListener('input', scheduleCounter);
  $('target-tag').addEventListener('change', scheduleCounter);

  const syncArchiveButton = (): void => {
    const owner = readerLock.current();
    const btn = $('archive') as HTMLButtonElement;
    btn.disabled = !isConnected() || owner !== null;
    btn.title = owner !== null && owner !== 'archive' ? t.readerBusyElsewhere : '';
    $('archive-hint').textContent = isConnected() ? '' : t.connectReaderFirst;
  };
  readerLock.onChange(syncArchiveButton);
  // Same reason as restore-panel's: a `t`-derived title is invisible to
  // applyStaticText(), so it must be re-derived on a locale change.
  onLocaleChange(syncArchiveButton);
  syncArchiveButton();

  const idleStatus = (): string =>
    !isConnected() ? t.archiveIdle : activeReaderName() === 'web-nfc' ? t.autoDetectNeedsChameleon : t.archiveReady;

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
    // Also skipped while the stage is showing (data-state set): after a run the
    // lock is released, but setStatus mirrors into #stage-headline, so this write
    // would overwrite the terminal "Done"/"Stopped" message. The form's status is
    // set by the Archive another / Back handler instead.
    if (connected && !archivingNow() && !$('panel-archive').hasAttribute('data-state')) {
      setStatus(idleStatus());
    }
  });

  let runAbort: AbortController | null = null;
  let lastOutcome: ArchiveOutcome | null = null;

  const againLabel = (): string => (lastOutcome === 'done' ? t.archiveAgain : t.back);

  const enterStage = (src: { data: Uint8Array; fileName: string }, compress: boolean, encrypted: boolean): void => {
    lastOutcome = null;
    $('panel-archive').setAttribute('data-state', 'writing');
    slotsWritten = 0; slotsTotal = 0; slotWarning = false;
    drawSlots();
    $('summary-name').textContent = src.fileName;
    const tag = ($('target-tag') as HTMLSelectElement).selectedOptions[0]?.textContent ?? '';
    $('summary-meta').textContent =
      [humanSize(src.data.length), compress ? 'GZIP' : '', encrypted ? 'AES-256' : '', tag].filter((x) => x !== '').join(' · ');
    // Reset the previous run's progress; indeterminate reads as "preparing".
    $('archive-progress').hidden = false;
    $('archive-progress-label').textContent = '';
    $('archive-progress-pct').textContent = '';
    bar.max = 1;
    bar.removeAttribute('value');
    $('archive-stop').hidden = false;
    ($('archive-stop') as HTMLButtonElement).disabled = false;
    $('stage-headline').removeAttribute('data-tone');
    $('archive-again').hidden = true;
    $('archive-stop').focus();
  };

  const leaveStage = (outcome: ArchiveOutcome): void => {
    lastOutcome = outcome;
    $('panel-archive').setAttribute('data-state', outcome);
    $('archive-stop').hidden = true;
    const again = $('archive-again');
    again.textContent = againLabel();
    again.hidden = false;
    if (outcome === 'failed') $('stage-headline').setAttribute('data-tone', 'error');
    again.focus();
  };

  $('archive-stop').addEventListener('click', () => {
    runAbort?.abort();
    ($('archive-stop') as HTMLButtonElement).disabled = true;
    $('stage-headline').textContent = t.stopping;
  });
  $('archive-again').addEventListener('click', () => {
    lastOutcome = null;
    $('panel-archive').removeAttribute('data-state');
    setStatus(idleStatus());
    const go = $('archive') as HTMLButtonElement;
    (go.disabled ? $(mode === 'file' ? 'source-file-btn' : 'source-text-btn') : go).focus();
  });
  onLocaleChange(() => {
    if (slotsTotal > 0) drawSlots();
    if (lastOutcome !== null) $('archive-again').textContent = againLabel();
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
      awaitReconnect: (signal) => new Promise<Transport>((resolve, reject) => {
        if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
        const live = currentTransport();
        if (isConnected() && live) { resolve(live); return; }
        const off = onConnectionChange(() => {
          const next = currentTransport();
          if (isConnected() && next) { off(); resolve(next); }
        });
        signal?.addEventListener('abort', () => { off(); reject(new DOMException('Aborted', 'AbortError')); }, { once: true });
      }),
      log,
    };

    if (!readerLock.acquire('archive')) { setStatus(t.readerBusyElsewhere, 'error'); return; }
    runAbort = new AbortController();
    enterStage(src, compress, pass.length > 0);
    let outcome: ArchiveOutcome = 'failed';
    try {
      outcome = await new ArchiveOrchestrator(io).run(transport, {
        data: src.data, fileName: src.fileName, compress,
        password: pass || undefined, payloadSize: selectedPayloadSize(),
      }, runAbort.signal);
    } catch (e) {
      hideProgress();
      setStatus(humanError(e), 'error');
    } finally {
      runAbort = null;
      readerLock.release('archive');
      leaveStage(outcome);
    }
  });
}
