/** Restore tab: thin adapter — builds the DOM/browser IO for RestoreOrchestrator and runs the scan-step loop. */
import { RestoreOrchestrator, type RestoreIO } from './restore-orchestrator.js';
import { CardAuthError, TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { currentTransport, isConnected, onConnectionChange } from './device.js';
import { readerLock } from './reader-lock.js';
import { filesController } from './files-panel.js';
import { humanError } from './errors.js';
import { mimeForFilename } from '../download-mime.js';
import { log } from '../../src/log/logger.js';
import { t, onLocaleChange } from '../i18n/index.js';
import { ensureMinInterval, FailureBreaker } from '../../src/loop-guards.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

export function initRestorePanel(): void {
  const setStatus = (msg: string) => { $('restore-status').textContent = msg; };
  let scanAbort: AbortController | null = null;

  const io: RestoreIO = {
    container: $('archives'),
    files: filesController,
    promptPassword: (message) => window.prompt(message),
    download: (data, name) => {
      const a = document.createElement('a');
      // Typed, not bare: an untyped Blob downloads as application/octet-stream,
      // and Android's viewer then has no charset for restored UTF-8 text.
      a.href = URL.createObjectURL(new Blob([data as BlobPart], { type: mimeForFilename(name) }));
      a.download = name;
      a.click();
      URL.revokeObjectURL(a.href);
    },
    fallbackName: () => ($('fname') as HTMLInputElement).value || 'restored.bin',
    setFileName: (name) => { ($('fname') as HTMLInputElement).value = name; },
    setStatus,
    log,
  };
  const orch = new RestoreOrchestrator(io);

  // Both buttons derive from connection state AND who holds the reader, so an
  // archive write in progress greys out Scan instead of letting a second loop
  // contend for taps. Driven by the lock's change notification, which fires
  // synchronously on acquire and release.
  const syncButtons = (): void => {
    const owner = readerLock.current();
    const scan = $('scan') as HTMLButtonElement;
    scan.disabled = !isConnected() || owner !== null;
    scan.title = owner !== null && owner !== 'scan' ? t.readerBusyElsewhere : '';
    ($('stop-scan') as HTMLButtonElement).disabled = owner !== 'scan';
  };
  onConnectionChange((connected) => {
    syncButtons();
    if (connected) setStatus(t.restoreReady);
  });
  readerLock.onChange(syncButtons);
  // The title is set from `t`, not from data-i18n markup, so applyStaticText()
  // never rewrites it — re-derive it here or a language switch mid-scan leaves
  // the tooltip in the old language. device.ts:onLocaleChange does the same for
  // its own inspectNeedsChameleon title.
  onLocaleChange(syncButtons);

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    // Refused if an archive (or an inspection) already owns the reader. The
    // button is disabled in that case, so this is the belt to that braces.
    if (!readerLock.acquire('scan')) return;
    orch.startSession(transport);
    scanAbort = new AbortController();
    setStatus(t.scanning);
    log.info('scan', 'Scan started');
    const breaker = new FailureBreaker();
    try {
      for (;;) {
        const iterationStart = Date.now();
        try {
          await orch.scanStep(scanAbort.signal);
          breaker.reset();
          setStatus(t.tapMoreCards);
        } catch (e) {
          if (e instanceof DOMException && e.name === 'AbortError') break;
          if (e instanceof TagTimeoutError) continue;
          // A restore pile legitimately contains foreign cards — tapping
          // several of them while sorting through a stack is normal use, not a
          // stuck loop, so neither may count toward the breaker. Both errors
          // are needed to cover "foreign card": UnsupportedTagError is only
          // raised for SAK values outside 0x00/0x08, so a foreign *Mifare
          // Classic* (SAK 0x08 — hotel key, transit card, office badge) routes
          // to the Classic transport instead and fails on its non-factory keys
          // with CardAuthError. Same user situation, different error.
          // (The archive loop exempts UnsupportedTagError for the same reason:
          // it can only arise after a real tap, so it is user-rate-limited and
          // cannot produce the spin the breaker exists to stop.)
          if (e instanceof UnsupportedTagError || e instanceof CardAuthError) {
            setStatus(t.unsupportedTapOther);
            log.warn('scan', 'Foreign card — skipped', { error: String(e) });
            continue;
          }
          // Waiting for the user is not failing: TagTimeoutError and an abort
          // (above) must never count toward the breaker — everything else does.
          await ensureMinInterval(iterationStart, 250);
          const name = e instanceof Error ? e.name : 'unknown';
          if (breaker.record(name)) {
            setStatus(t.scanGaveUp(humanError(e)));
            log.error('scan', 'Stopped after repeated failures', { error: String(e) });
            break;
          }
          setStatus(t.skippedCard(humanError(e)));
          log.warn('scan', 'Skipped a card', { error: String(e) });
          continue;
        }
      }
    } finally {
      readerLock.release('scan');
      log.info('scan', 'Scan stopped');
    }
  });

  $('stop-scan').addEventListener('click', () => { scanAbort?.abort(); });
}
