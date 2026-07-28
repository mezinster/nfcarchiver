/**
 * Renders the stored-files list by reconciling in place: one stable row +
 * Download/Delete buttons per file id, updated on each call (like restore-view.ts),
 * so a click is never lost to a DOM teardown.
 */
import type { FileListItem } from '../../src/storage/file-store.js';

export function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function label(f: FileListItem): string {
  const when = new Date(f.createdAt).toLocaleString();
  return `${f.name}  ·  ${humanSize(f.size)}  ·  ${when}  ·  ${f.isEncrypted ? '🔒 encrypted' : 'plain'}  ·  ${f.totalChunks} card(s)`;
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
      row.className = 'file';
      row.setAttribute('data-file-id', f.id);
      const span = doc.createElement('span');
      const dl = doc.createElement('button');
      dl.textContent = 'Download';
      dl.addEventListener('click', () => handlers.onDownload(f.id));
      const del = doc.createElement('button');
      del.textContent = 'Delete';
      del.addEventListener('click', () => handlers.onDelete(f.id));
      row.append(span, dl, del);
      container.appendChild(row);
      existing.set(f.id, row);
    }
    (row.children[0] as HTMLElement).textContent = label(f);
  }
}
