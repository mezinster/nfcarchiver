/** Log tab: live view of the in-app event log with min-level filter + export. */
import { log, formatLogLine, LEVELS, type LogEntry, type LogLevel } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

export function initLogPanel(): void {
  const box = $('log');
  const levelSel = $('log-level') as HTMLSelectElement;
  const autoscroll = $('log-autoscroll') as HTMLInputElement;
  const consoleChk = $('log-console') as HTMLInputElement;
  const minLevel = (): number => LEVELS[levelSel.value as LogLevel] ?? 0;

  const addRow = (e: LogEntry): void => {
    const row = document.createElement('div');
    row.dataset['level'] = e.level;
    row.textContent = formatLogLine(e);
    row.hidden = LEVELS[e.level] < minLevel();
    box.appendChild(row);
    while (box.children.length > 1000) box.firstChild?.remove();
    if (autoscroll.checked) box.scrollTop = box.scrollHeight;
  };

  const rerender = (): void => {
    box.replaceChildren(); // log rows are non-interactive text — safe to rebuild
    for (const e of log.snapshot()) addRow(e);
  };

  rerender();
  log.subscribe(addRow);

  levelSel.addEventListener('change', () => {
    const min = minLevel();
    for (const row of Array.from(box.children) as HTMLElement[]) {
      const lvl = row.dataset['level'] as LogLevel | undefined;
      row.hidden = lvl === undefined ? false : LEVELS[lvl] < min;
    }
  });
  consoleChk.addEventListener('change', () => log.setMirrorToConsole(consoleChk.checked));
  $('log-clear').addEventListener('click', () => { log.clear(); rerender(); });
  $('log-copy').addEventListener('click', () => {
    void navigator.clipboard?.writeText(log.snapshot().map(formatLogLine).join('\n'));
  });
  $('log-download').addEventListener('click', () => {
    const text = log.snapshot().map(formatLogLine).join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    a.download = `nfc-archiver-log-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  });
}
