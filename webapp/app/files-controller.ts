/**
 * DOM-free orchestration for the Files tab over a FileStore. Captures restored
 * archives (assembled payload + cleartext metadata) and re-derives the plaintext
 * on download, re-prompting the password for encrypted entries.
 */

import type { FileStore, StoredFile, FileListItem, StorageInfo } from '../src/storage/file-store.js';
import { restoreFromPayload } from '../src/pipeline.js';
import { unwrapFilename } from '../src/filename.js';
import { PasswordRequiredError } from './controller.js';

export class FilesController {
  constructor(private readonly store: FileStore) {}

  async list(): Promise<FileListItem[]> {
    return (await this.store.list()).map(({ payload: _payload, ...meta }) => meta);
  }

  info(): Promise<StorageInfo> {
    return this.store.info();
  }

  delete(id: string): Promise<void> {
    return this.store.delete(id);
  }

  clear(): Promise<number> {
    return this.store.clear();
  }

  saveRestored(entry: Omit<StoredFile, 'createdAt'>): Promise<void> {
    return this.store.save({ ...entry, createdAt: Date.now() });
  }

  async prepareDownload(id: string, password?: string): Promise<{ data: Uint8Array; name: string }> {
    const rec = await this.store.get(id);
    if (rec === null) throw new Error(`No stored file ${id}`);
    if (rec.isEncrypted && password === undefined) {
      throw new PasswordRequiredError('This file is encrypted; a password is required');
    }
    const wrapped = await restoreFromPayload(
      rec.payload,
      { isEncrypted: rec.isEncrypted, isCompressed: rec.isCompressed },
      password,
    );
    const { fileName, data } = unwrapFilename(wrapped);
    return { data, name: fileName ?? rec.name };
  }
}
