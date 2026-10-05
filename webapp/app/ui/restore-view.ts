/**
 * Renders the detected-archives list by reconciling in place: one stable
 * row + Restore button per archive id, updated on each call. Nothing is torn
 * down and rebuilt, so a button (and its click listener) survives the scan
 * loop's high-frequency re-renders — a click on a resting card can never be
 * lost to a mid-interaction DOM teardown.
 */
import type { DetectedArchive } from '../controller.js';
import { t } from '../i18n/index.js';

/** Above this many cards the dot row would not fit; the "k/N" text remains. */
export const MAX_DOTS = 10;

function dots(received: number, total: number): string {
  if (total > MAX_DOTS) return '';
  let html = '';
  for (let i = 0; i < total; i++) html += i < received ? '<i class="dot on"></i>' : '<i class="dot"></i>';
  return html;
}

export function renderArchiveList(
  container: HTMLElement,
  list: DetectedArchive[],
  onPick: (id: string) => void,
): void {
  const doc = container.ownerDocument;
  const existing = new Map<string, HTMLElement>();
  for (const row of Array.from(container.children) as HTMLElement[]) {
    const id = row.getAttribute('data-archive-id');
    if (id !== null) existing.set(id, row);
  }
  const wanted = new Set(list.map((a) => a.archiveId));
  for (const [id, row] of existing) if (!wanted.has(id)) row.remove();

  for (const a of list) {
    let row = existing.get(a.archiveId);
    if (row === undefined) {
      row = doc.createElement('div');
      row.className = 'row';
      row.setAttribute('data-archive-id', a.archiveId);

      const tile = doc.createElement('span');
      tile.className = 'icon-tile';
      tile.innerHTML = '<svg class="ico"><use href="#i-card"/></svg>';

      const text = doc.createElement('div');
      text.className = 'row-text';
      const name = doc.createElement('div');
      name.className = 'row-name mono';
      const sub = doc.createElement('div');
      sub.className = 'row-sub';
      const dotsEl = doc.createElement('span');
      dotsEl.className = 'dots';
      const status = doc.createElement('span');
      status.className = 'row-status';
      sub.append(dotsEl, status);
      text.append(name, sub);

      const control = doc.createElement('div');
      control.className = 'row-control';
      const newBtn = doc.createElement('button');
      newBtn.className = 'btn btn-tonal';
      // The row's archive id never changes, so binding it once is safe and keeps
      // the listener stable across updates.
      newBtn.addEventListener('click', () => onPick(a.archiveId));
      control.append(newBtn);

      row.append(tile, text, control);
      container.appendChild(row);
      existing.set(a.archiveId, row);
    }
    const text = row.children[1] as HTMLElement;
    const sub = text.children[1] as HTMLElement;
    const btn = (row.children[2] as HTMLElement).children[0] as HTMLButtonElement;
    // Labels are rewritten on every render, not only at creation: rows outlive
    // a language switch, so text would otherwise stay in the boot language.
    (text.children[0] as HTMLElement).textContent = `#${a.shortId}`;
    (sub.children[0] as HTMLElement).innerHTML = dots(a.received, a.totalChunks);
    (sub.children[1] as HTMLElement).textContent = t.archiveRowStatus(a.received, a.totalChunks, a.complete);
    row.setAttribute('data-encrypted', String(a.isEncrypted));
    row.setAttribute('data-complete', String(a.complete));
    btn.textContent = t.restore;
    btn.disabled = !a.complete;
  }
}
