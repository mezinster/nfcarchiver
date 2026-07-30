/** Restore tab: thin adapter — builds the DOM/browser IO for RestoreOrchestrator and runs the scan-step loop. */
import { RestoreOrchestrator, type RestoreIO } from './restore-orchestrator.js';
import { TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { currentTransport, onConnectionChange, setReaderBusy } from './device.js';
import { filesController } from './files-panel.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';

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
    if (connected) setStatus('Scan a pile of cards to detect archives.');
  });

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    orch.startSession(transport);
    scanAbort = new AbortController();
    ($('scan') as HTMLButtonElement).disabled = true;
    ($('stop-scan') as HTMLButtonElement).disabled = false;
    setStatus('Scanning — tap cards on the reader…');
    setReaderBusy(true);
    log.info('scan', 'Scan started');
    try {
      for (;;) {
        try {
          await orch.scanStep(scanAbort.signal);
          setStatus('Tap more cards, or Restore a complete one.');
        } catch (e) {
          if (e instanceof DOMException && e.name === 'AbortError') break;
          if (e instanceof TagTimeoutError) continue;
          if (e instanceof UnsupportedTagError) { setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.'); log.warn('scan', 'Unsupported tag'); continue; }
          setStatus(`Skipped a card: ${humanError(e)}`);
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
