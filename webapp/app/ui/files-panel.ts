/** Files tab: list restored archives from IndexedDB, re-download, delete, clear. */
import { FilesController } from '../files-controller.js';
import { IdbFileStore } from '../../src/storage/idb-file-store.js';
import { renderFileList, humanSize } from './files-view.js';
import { PasswordRequiredError } from '../controller.js';
import { DecryptionError } from '../../src/crypto.js';
import { humanError } from './errors.js';
import { mimeForFilename } from '../download-mime.js';
import { log } from '../../src/log/logger.js';
import { t } from '../i18n/index.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

/** Shared so restore-panel can persist into the same store. */
export const filesController = new FilesController(new IdbFileStore());

async function download(id: string, setStatus: (m: string) => void): Promise<void> {
  let pw: string | undefined;
  for (let attempt = 0; attempt <= 5; attempt++) {
    try {
      const { data, name } = await filesController.prepareDownload(id, pw);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([data as BlobPart], { type: mimeForFilename(name) }));
      a.download = name;
      a.click();
      URL.revokeObjectURL(a.href);
      setStatus(t.downloadedTo(humanSize(data.length), name));
      log.info('files', 'Downloaded', { id, name });
      return;
    } catch (e) {
      if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
        if (attempt === 5) break;
        const entered = prompt(e instanceof DecryptionError ? t.promptWrongPassword : t.promptFileEncrypted) ?? undefined;
        if (entered === undefined) { setStatus(t.cancelled); return; }
        pw = entered; continue;
      }
      setStatus(humanError(e));
      return;
    }
  }
  setStatus(t.tooManyPasswordAttempts);
}

export function initFilesPanel(): void {
  const setStatus = (m: string) => { $('files-status').textContent = m; };

  const refresh = async (): Promise<void> => {
    try {
      const files = await filesController.list();
      renderFileList($('files'), files, {
        onDownload: (id) => { void download(id, setStatus); },
        onDelete: async (id) => { await filesController.delete(id); log.info('files', 'Deleted', { id }); await refresh(); },
      });
      const info = await filesController.info();
      $('files-empty').hidden = info.count > 0;
      $('files-info').textContent = info.count === 0 ? '' : t.filesInfo(info.count, humanSize(info.totalBytes));
    } catch (e) {
      setStatus(humanError(e));
    }
  };

  $('files-clear').addEventListener('click', async () => {
    if (!confirm(t.confirmClearAll)) return;
    const n = await filesController.clear();
    log.info('files', 'Cleared', { count: n });
    await refresh();
    setStatus(t.clearedFiles(n));
  });

  // Refresh whenever the Files tab is opened (and once at startup).
  document.querySelector<HTMLButtonElement>('#tabs button[data-tab="files"]')!
    .addEventListener('click', () => { void refresh(); });
  void refresh();
}
