/**
 * Renders the stored-files list by reconciling in place: one stable row +
 * Download/Delete buttons per file id, updated on each call (like restore-view.ts),
 * so a click is never lost to a DOM teardown.
 */
import type { FileListItem } from '../../src/storage/file-store.js';
import { t } from '../i18n/index.js';

export function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function label(f: FileListItem): string {
  const when = new Date(f.createdAt).toLocaleString();
  return t.fileRow(f.name, humanSize(f.size), when, f.isEncrypted, f.totalChunks);
}

export function renderFileList(
  container: HTMLElement,
  files: FileListItem[],
  handlers: { onDownload: (id: string) => void; onDelete: (id: string) => void },
): void {
  const doc = container.ownerDocument;
  const existing = new Map<string, HTMLElement>();
  for (const row of Array.from(container.children) as HTMLElement[]) {
    const id = row.getAttribute('data-file-id');
    if (id !== null) existing.set(id, row);
  }
  const wanted = new Set(files.map((f) => f.id));
  for (const [id, row] of existing) if (!wanted.has(id)) row.remove();

  for (const f of files) {
    let row = existing.get(f.id);
    if (row === undefined) {
      row = doc.createElement('div');
      row.className = 'row';
      row.setAttribute('data-file-id', f.id);

      const tile = doc.createElement('span');
      tile.className = 'icon-tile';
      tile.innerHTML = '<svg class="ico"><use href="#i-folder"/></svg>';

      const text = doc.createElement('div');
      text.className = 'row-text';
      const name = doc.createElement('div');
      name.className = 'row-name';
      text.append(name);

      const control = doc.createElement('div');
      control.className = 'row-control';
      const dl = doc.createElement('button');
      dl.className = 'btn-tonal';
      dl.addEventListener('click', () => handlers.onDownload(f.id));
      const del = doc.createElement('button');
      del.className = 'btn-text';
      del.addEventListener('click', () => handlers.onDelete(f.id));
      control.append(dl, del);

      row.append(tile, text, control);
      container.appendChild(row);
      existing.set(f.id, row);
    }
    // Every label is rewritten on each render, not just at row creation: the
    // rows outlive a language switch, so button text would otherwise stay
    // frozen in the boot language forever.
    const controls = row.children[2] as HTMLElement;
    ((row.children[1] as HTMLElement).children[0] as HTMLElement).textContent = label(f);
    (controls.children[0] as HTMLElement).textContent = t.download;
    (controls.children[1] as HTMLElement).textContent = t.deleteBtn;
  }
}
