/**
 * DOM-light restore/scan orchestration behind an injected IO seam. Restoring is
 * decoupled from the scan loop: each rendered Restore button calls
 * restoreArchive(id) directly, so it works during a scan, after Stop, and
 * repeatedly for different archives. The panel supplies the real DOM/browser IO;
 * tests supply a DOM stub + MockTransport.
 */
import { RestoreController, PasswordRequiredError } from '../controller.js';
import { DecryptionError } from '../../src/crypto.js';
import { renderArchiveList } from './restore-view.js';
import { humanError } from './errors.js';
import type { Transport } from '../../src/transport/transport.js';
import type { StoredFile } from '../../src/storage/file-store.js';
import type { Logger } from '../../src/log/logger.js';

export interface RestoreIO {
  container: HTMLElement;
  files: { saveRestored(e: Omit<StoredFile, 'createdAt'>): Promise<void> };
  promptPassword(message: string): string | null;
  download(data: Uint8Array, name: string): void;
  fallbackName(): string;
  setFileName(name: string): void;
  setStatus(msg: string): void;
  log: Logger;
}

export class RestoreOrchestrator {
  private ctrl: RestoreController | null = null;
  private restoring = false;

  constructor(private readonly io: RestoreIO) {}

  private render(list: Parameters<typeof renderArchiveList>[1]): void {
    renderArchiveList(this.io.container, list, (id) => this.restoreArchive(id));
  }

  startSession(transport: Transport): void {
    this.ctrl = new RestoreController(transport);
    this.render([]); // clear any rows from a previous session
    this.io.log.info('scan', 'Session started');
  }

  async scanStep(signal: AbortSignal): Promise<void> {
    if (this.ctrl === null) throw new Error('scanStep before startSession');
    const list = await this.ctrl.scanNextCard(signal);
    this.render(list);
    this.io.log.debug('scan', 'Detection', { archives: list.length, complete: list.filter((d) => d.complete).length });
  }

  async restoreArchive(id: string): Promise<void> {
    if (this.ctrl === null) { this.io.log.warn('restore', 'Ignored: no session', { id }); return; }
    if (this.restoring) { this.io.log.warn('restore', 'Ignored: already restoring', { id }); return; }
    const ctrl = this.ctrl;
    this.restoring = true;
    this.io.log.info('restore', 'Restore clicked', { id });
    try {
      let pw: string | undefined;
      let result: { data: Uint8Array; fileName: string | null } | undefined;
      // attempt 0 tries with no password (unencrypted archives succeed here);
      // then up to 5 user-entered passwords are each actually tried.
      for (let attempt = 0; attempt <= 5; attempt++) {
        try { result = await ctrl.restore(id, pw); break; }
        catch (e) {
          if (!(e instanceof PasswordRequiredError || e instanceof DecryptionError)) throw e;
          if (attempt === 5) break; // 5 passwords already tried
          const entered = this.io.promptPassword(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:');
          if (entered === null) { this.io.setStatus('Cancelled.'); this.io.log.info('restore', 'Cancelled', { id }); return; }
          pw = entered;
        }
      }
      if (!result) { this.io.setStatus('Too many failed password attempts.'); this.io.log.warn('restore', 'Too many password attempts', { id }); return; }
      const name = result.fileName ?? this.io.fallbackName();
      if (result.fileName) this.io.setFileName(result.fileName);
      this.io.download(result.data, name);
      this.io.setStatus(`Restored ${result.data.length} bytes → ${name}.`);
      this.io.log.info('restore', 'Restored', { id, bytes: result.data.length, name });
      try {
        const meta = ctrl.detectedArchives().find((d) => d.archiveId === id);
        if (meta) {
          await this.io.files.saveRestored({
            id, name: result.fileName ?? name, size: result.data.length,
            isEncrypted: meta.isEncrypted, isCompressed: meta.isCompressed,
            totalChunks: meta.totalChunks, payload: ctrl.assembledPayload(id),
          });
          this.io.log.info('files', 'Saved to history', { id });
        }
      } catch (e) {
        this.io.log.warn('files', 'History save failed (non-fatal)', { id, error: String(e) });
      }
    } catch (e) {
      this.io.setStatus(humanError(e));
      this.io.log.error('restore', 'Restore failed', { id, error: String(e) });
    } finally {
      this.restoring = false;
    }
  }
}
