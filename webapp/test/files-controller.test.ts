import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryFileStore, type StoredFile } from '../src/storage/file-store.js';
import { FilesController } from '../app/files-controller.js';
import { archive } from '../src/pipeline.js';
import { assembleChunks } from '../src/chunker.js';
import { wrapWithFilename } from '../src/filename.js';
import { FLAG_COMPRESSED, FLAG_ENCRYPTED } from '../src/chunk.js';
import { PasswordRequiredError } from '../app/controller.js';
import { DecryptionError } from '../src/crypto.js';

/** Build a StoredFile entry the way restore-panel will, for `fileName`/`data`. */
async function makeEntry(
  id: string, fileName: string, data: Uint8Array, opts: { compress?: boolean; password?: string },
): Promise<Omit<StoredFile, 'createdAt'>> {
  const chunks = await archive(wrapWithFilename(data, fileName), { payloadSize: 720, ...opts });
  const flags = chunks[0]!.flags;
  return {
    id, name: fileName, size: data.length,
    isEncrypted: (flags & FLAG_ENCRYPTED) !== 0,
    isCompressed: (flags & FLAG_COMPRESSED) !== 0,
    totalChunks: chunks.length,
    payload: assembleChunks(chunks),
  };
}

test('saveRestored stamps createdAt and list() strips the payload', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('a', 'a.bin', new Uint8Array([1, 2, 3]), {}));
  const list = await ctrl.list();
  assert.equal(list.length, 1);
  assert.equal(list[0]!.name, 'a.bin');
  assert.ok(list[0]!.createdAt > 0);
  assert.equal((list[0] as Record<string, unknown>).payload, undefined);
});

test('prepareDownload round-trips a plain entry with no password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  const data = crypto.getRandomValues(new Uint8Array(300));
  await ctrl.saveRestored(await makeEntry('p', 'notes.txt', data, {}));
  const out = await ctrl.prepareDownload('p');
  assert.equal(out.name, 'notes.txt');
  assert.deepEqual(out.data, data);
});

test('prepareDownload round-trips an encrypted+compressed entry with the password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  const data = crypto.getRandomValues(new Uint8Array(400));
  await ctrl.saveRestored(await makeEntry('e', 'secret.bin', data, { compress: true, password: 'pw' }));
  const out = await ctrl.prepareDownload('e', 'pw');
  assert.deepEqual(out.data, data);
});

test('prepareDownload throws PasswordRequiredError for an encrypted entry with no password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('e', 's.bin', new Uint8Array([9]), { password: 'pw' }));
  await assert.rejects(() => ctrl.prepareDownload('e'), PasswordRequiredError);
});

test('prepareDownload throws DecryptionError for a wrong password', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('e', 's.bin', new Uint8Array([9]), { password: 'pw' }));
  await assert.rejects(() => ctrl.prepareDownload('e', 'wrong'), DecryptionError);
});

test('prepareDownload throws for an unknown id', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await assert.rejects(() => ctrl.prepareDownload('nope'));
});

test('delete and clear mutate the store; info reports bytes', async () => {
  const ctrl = new FilesController(new InMemoryFileStore());
  await ctrl.saveRestored(await makeEntry('a', 'a.bin', new Uint8Array(50), {}));
  await ctrl.saveRestored(await makeEntry('b', 'b.bin', new Uint8Array(50), {}));
  const info1 = await ctrl.info();
  assert.equal(info1.count, 2);
  assert.ok(info1.totalBytes > 0);
  await ctrl.delete('a');
  assert.equal((await ctrl.list()).length, 1);
  assert.equal(await ctrl.clear(), 1);
  assert.equal((await ctrl.info()).count, 0);
});
