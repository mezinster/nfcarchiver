/**
 * The Inspect card dialog: a thin adapter binding the DOM to InspectIO. All
 * logic lives in inspect-orchestrator.ts; this file only moves strings into
 * elements and wires Copy/Download/Close.
 *
 * Closing the dialog aborts the remaining reads — a full dump is ~64 BLE round
 * trips, and there is no reason to keep the reader busy once nobody is looking.
 */
import { runInspection, type InspectIO } from './inspect-orchestrator.js';
import type { ChameleonDevice } from '../../src/transport/chameleon-device.js';
import type { RawAntiColl } from '../diagnostics.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

let running = false;
let wired = false;
let report = '';
let rows: string[] = [];
let currentAbort: AbortController | null = null;

export function openInspector(
  dev: ChameleonDevice,
  raw: RawAntiColl,
  setReaderBusy: (busy: boolean) => void,
): void {
  if (running) return;
  const dialog = $('inspect-dialog') as HTMLDialogElement;
  const identity = $('inspect-identity');
  const nfar = $('inspect-nfar');
  const rawPre = $('inspect-raw');
  const progress = $('inspect-progress');
  const status = $('inspect-status');

  identity.textContent = '';
  nfar.textContent = '';
  rawPre.textContent = '';
  progress.textContent = '';
  status.textContent = '';

  report = '';
  rows = [];
  const ac = new AbortController();
  currentAbort = ac;

  // Each callback checks that this inspection is still the current one before
  // touching shared state or the DOM. A superseded inspection's trailing
  // callback (a BLE read that was in flight when abort() fired, and resolves
  // after the loop notices but before the promise settles) becomes a no-op
  // instead of overwriting the next inspection's data.
  const io: InspectIO = {
    setIdentity: (t) => { if (currentAbort !== ac) return; identity.textContent = t; },
    setNfar: (t) => { if (currentAbort !== ac) return; nfar.textContent = t; },
    appendRow: (line) => { if (currentAbort !== ac) return; rows.push(line); rawPre.textContent = rows.join('\n'); },
    setProgress: (t) => { if (currentAbort !== ac) return; progress.textContent = t; },
    setReport: (t) => { if (currentAbort !== ac) return; report = t; },
    setStatus: (t) => { if (currentAbort !== ac) return; status.textContent = t; },
  };

  if (!wired) {
    dialog.addEventListener('close', () => { currentAbort?.abort(); });
    $('inspect-close').addEventListener('click', () => dialog.close());

    $('inspect-copy').addEventListener('click', () => {
      void navigator.clipboard.writeText(report || rows.join('\n'));
    });

    $('inspect-download').addEventListener('click', () => {
      const blob = new Blob([report || rows.join('\n')], { type: 'text/plain' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `card-inspection-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
      a.click();
      URL.revokeObjectURL(a.href);
    });
    wired = true;
  }

  dialog.showModal();
  running = true;
  setReaderBusy(true);
  log.info('inspect', 'Inspection started');
  void runInspection(dev, raw, io, ac.signal)
    .catch((e: unknown) => { if (currentAbort === ac) status.textContent = String(e); })
    .finally(() => {
      // running (and the reader-busy gate) must be released unconditionally
      // regardless of which inspection this is, or a superseded run's finally
      // would never fire (there is none pending) while a still-running one
      // would leave the button permanently disabled if guarded on the epoch.
      running = false;
      setReaderBusy(false);
      log.info('inspect', 'Inspection finished', { rows: rows.length });
    });
}
