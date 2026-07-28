import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryFileStore, type StoredFile } from '../src/storage/file-store.js';

const mk = (over: Partial<StoredFile>): StoredFile => ({
  id: 'id-1', name: 'a.bin', size: 3, createdAt: 1000,
  isEncrypted: false, isCompressed: false, totalChunks: 1,
  payload: new Uint8Array([1, 2, 3]), ...over,
});

test('save + get round-trips a record', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({}));
  const got = await s.get('id-1');
  assert.equal(got?.name, 'a.bin');
  assert.deepEqual([...(got!.payload)], [1, 2, 3]);
});

test('get returns null for a missing id', async () => {
  const s = new InMemoryFileStore();
  assert.equal(await s.get('nope'), null);
});

test('list returns records newest-first by createdAt', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'old', createdAt: 100 }));
  await s.save(mk({ id: 'new', createdAt: 200 }));
  const ids = (await s.list()).map((f) => f.id);
  assert.deepEqual(ids, ['new', 'old']);
});

test('save upserts by id (no duplicates)', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'x', name: 'first' }));
  await s.save(mk({ id: 'x', name: 'second' }));
  const list = await s.list();
  assert.equal(list.length, 1);
  assert.equal(list[0]!.name, 'second');
});

test('delete removes one record', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'x' }));
  await s.delete('x');
  assert.equal(await s.get('x'), null);
});

test('clear empties the store and returns the count removed', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'a' }));
  await s.save(mk({ id: 'b' }));
  assert.equal(await s.clear(), 2);
  assert.equal((await s.list()).length, 0);
});

test('info reports count and summed payload bytes', async () => {
  const s = new InMemoryFileStore();
  await s.save(mk({ id: 'a', payload: new Uint8Array(10) }));
  await s.save(mk({ id: 'b', payload: new Uint8Array(15) }));
  assert.deepEqual(await s.info(), { count: 2, totalBytes: 25 });
});
