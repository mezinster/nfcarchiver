/** Restore tab: thin adapter — builds the DOM/browser IO for RestoreOrchestrator and runs the scan-step loop. */
import { RestoreOrchestrator, type RestoreIO } from './restore-orchestrator.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { currentTransport, onConnectionChange, setReaderBusy } from './device.js';
import { filesController } from './files-panel.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';
import { t } from '../i18n/index.js';
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
      a.href = URL.createObjectURL(new Blob([data as BlobPart]));
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

  onConnectionChange((connected) => {
    ($('scan') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus(t.restoreReady);
  });

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    orch.startSession(transport);
    scanAbort = new AbortController();
    ($('scan') as HTMLButtonElement).disabled = true;
    ($('stop-scan') as HTMLButtonElement).disabled = false;
    setStatus(t.scanning);
    setReaderBusy(true);
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
          // several unsupported ones while sorting through a stack is normal
          // use, not a stuck loop, so this must never count toward the
          // breaker. (Unlike the archive loop, where a wrong-media tap during
          // an active write IS a genuine failure to progress — see
          // archive-orchestrator.ts for the mirror case.)
          if (e instanceof UnsupportedTagError) { setStatus(t.unsupportedTapOther); log.warn('scan', 'Unsupported tag'); continue; }
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
      setReaderBusy(false);
      ($('stop-scan') as HTMLButtonElement).disabled = true;
      ($('scan') as HTMLButtonElement).disabled = false;
      log.info('scan', 'Scan stopped');
    }
  });

  $('stop-scan').addEventListener('click', () => { scanAbort?.abort(); });
}
