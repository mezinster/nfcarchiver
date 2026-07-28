/**
 * Persistent FileStore over IndexedDB. This is the ONLY module that touches the
 * indexedDB global (the storage fence). Records persist via structured clone, so
 * the Uint8Array payload is stored natively — no base64.
 */
import type { FileStore, StoredFile, StorageInfo } from './file-store.js';

const DB_NAME = 'nfcarchiver';
const STORE = 'files';

export class IdbFileStore implements FileStore {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private open(): Promise<IDBDatabase> {
    if (this.dbPromise === null) {
      this.dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
          if (!req.result.objectStoreNames.contains(STORE)) {
            req.result.createObjectStore(STORE, { keyPath: 'id' });
          }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error('IndexedDB open failed'));
      });
    }
    return this.dbPromise;
  }

  private async tx<T>(mode: IDBTransactionMode, fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open();
    return new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      let result: T;
      req.onsuccess = () => {
        result = req.result;
      };
      // Resolve only once the transaction actually COMMITS. A readwrite request can
      // fire onsuccess and the surrounding transaction can still abort at commit time
      // (e.g. QuotaExceededError) -- resolving on req.onsuccess alone would report
      // success for a record that never persisted. oncomplete fires after onsuccess,
      // so this is correct for readonly reads too.
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => reject(tx.error ?? req.error ?? new Error('IndexedDB transaction failed'));
      tx.onabort = () => reject(tx.error ?? req.error ?? new Error('IndexedDB transaction failed'));
    });
  }

  async list(): Promise<StoredFile[]> {
    const all = await this.tx<StoredFile[]>('readonly', (s) => s.getAll() as IDBRequest<StoredFile[]>);
    return all.sort((a, b) => b.createdAt - a.createdAt);
  }
  async save(file: StoredFile): Promise<void> {
    await this.tx('readwrite', (s) => s.put(file));
  }
  async get(id: string): Promise<StoredFile | null> {
    const rec = await this.tx<StoredFile | undefined>('readonly', (s) => s.get(id) as IDBRequest<StoredFile | undefined>);
    return rec ?? null;
  }
  async delete(id: string): Promise<void> {
    await this.tx('readwrite', (s) => s.delete(id));
  }
  async clear(): Promise<number> {
    const count = await this.tx<number>('readonly', (s) => s.count());
    await this.tx('readwrite', (s) => s.clear());
    return count;
  }
  async info(): Promise<StorageInfo> {
    const all = await this.list();
    let totalBytes = 0;
    for (const r of all) totalBytes += r.payload.length;
    return { count: all.length, totalBytes };
  }
}
