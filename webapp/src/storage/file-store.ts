/**
 * Local store of restored archives. `InMemoryFileStore` backs the record with a
 * Map and is the store used by all unit tests; `IdbFileStore` (browser) provides
 * the persistent implementation of the same contract.
 */

export interface StoredFile {
  id: string;            // archive UUID string; primary key (upsert de-dupes re-restores)
  name: string;          // recovered filename (cleartext metadata)
  size: number;          // plaintext byte length, for display
  createdAt: number;     // epoch ms when saved
  isEncrypted: boolean;
  isCompressed: boolean;
  totalChunks: number;   // card count
  payload: Uint8Array;   // assembled chunk payload: ciphertext if encrypted, else wrapped(+gzip) plaintext
}

export type FileListItem = Omit<StoredFile, 'payload'>;

export interface StorageInfo {
  count: number;
  totalBytes: number;
}

export interface FileStore {
  list(): Promise<StoredFile[]>;         // newest-first (createdAt desc)
  save(file: StoredFile): Promise<void>; // upsert by id
  get(id: string): Promise<StoredFile | null>;
  delete(id: string): Promise<void>;
  clear(): Promise<number>;              // returns number of records removed
  info(): Promise<StorageInfo>;
}

export class InMemoryFileStore implements FileStore {
  private readonly records = new Map<string, StoredFile>();

  async list(): Promise<StoredFile[]> {
    return [...this.records.values()].sort((a, b) => b.createdAt - a.createdAt);
  }
  async save(file: StoredFile): Promise<void> {
    this.records.set(file.id, file);
  }
  async get(id: string): Promise<StoredFile | null> {
    return this.records.get(id) ?? null;
  }
  async delete(id: string): Promise<void> {
    this.records.delete(id);
  }
  async clear(): Promise<number> {
    const n = this.records.size;
    this.records.clear();
    return n;
  }
  async info(): Promise<StorageInfo> {
    let totalBytes = 0;
    for (const r of this.records.values()) totalBytes += r.payload.length;
    return { count: this.records.size, totalBytes };
  }
}
