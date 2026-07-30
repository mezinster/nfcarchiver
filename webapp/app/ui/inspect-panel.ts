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

export function openInspector(dev: ChameleonDevice, raw: RawAntiColl): void {
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
  const io: InspectIO = {
    setIdentity: (t) => { identity.textContent = t; },
    setNfar: (t) => { nfar.textContent = t; },
    appendRow: (line) => { rows.push(line); rawPre.textContent = rows.join('\n'); },
    setProgress: (t) => { progress.textContent = t; },
    setReport: (t) => { report = t; },
    setStatus: (t) => { status.textContent = t; },
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

  const ac = new AbortController();
  currentAbort = ac;

  dialog.showModal();
  running = true;
  log.info('inspect', 'Inspection started');
  void runInspection(dev, raw, io, ac.signal)
    .catch((e: unknown) => { status.textContent = String(e); })
    .finally(() => {
      running = false;
      log.info('inspect', 'Inspection finished', { rows: rows.length });
    });
}
