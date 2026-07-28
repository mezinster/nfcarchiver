import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { decodeChunk, encodeChunk } from '../src/chunk.js';
import { ArchiveController, RestoreController, PasswordRequiredError, OverwriteRequiredError } from '../app/controller.js';
import { DecryptionError } from '../src/crypto.js';
import { NfarAssemblyError } from '../src/chunker.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
const multiCardData = crypto.getRandomValues(new Uint8Array(2000)); // incompressible -> multiple cards

/** Archive `data` to a source transport and return each card's stored bytes, in order. */
async function archiveToCards(
  data: Uint8Array, opts: { compress: boolean; password?: string; fileName?: string },
): Promise<Uint8Array[]> {
  const src = new MockTransport();
  const ctrl = new ArchiveController(src);
  const total = await ctrl.prepare({ data, fileName: opts.fileName ?? 'blob.bin', compress: opts.compress, password: opts.password, payloadSize: 720 });
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i));
    await ctrl.writeNextCard();
    src.enqueueTag(uid(i));
    await src.awaitTag();
    stored.push(await src.readChunk());
  }
  return stored;
}

test('archive writes each card once and reports progress', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  assert.ok(total >= 2, `expected multiple cards, got ${total}`);
  for (let i = 0; i < total; i++) t.enqueueTag(uid(i));
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await ctrl.writeNextCard());
  assert.ok(done);
});

test('archive skips a re-tapped card it already wrote', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  assert.ok(total >= 2);
  t.enqueueTag(uid(0));
  const first = await ctrl.writeNextCard();
  assert.equal(first.progress.written, 1);
  t.enqueueTag(uid(0));
  const repeat = await ctrl.writeNextCard();
  assert.equal(repeat.progress.written, 1);
  assert.equal(repeat.done, false);
});

test('archive requires explicit confirmation to overwrite an NFAR card', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  const existingNfar = encodeChunk({
    archiveId: new Uint8Array(16).fill(1), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  t.enqueueTag(uid(7), existingNfar);
  await assert.rejects(() => ctrl.writeNextCard(undefined, false), OverwriteRequiredError);
  t.enqueueTag(uid(7), existingNfar);
  const ok = await ctrl.writeNextCard(undefined, true);
  assert.equal(ok.progress.written, 1);
});

test('restore recovers the filename and demands a password when encrypted', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, password: 'pw', fileName: 'notes.txt' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((bytes, i) => rt.enqueueTag(uid(i), bytes));

  let detected = await rctrl.scanNextCard();
  let guard = 0;
  while (!detected[0]!.complete && guard++ < 50) detected = await rctrl.scanNextCard();
  assert.equal(detected.length, 1);
  assert.ok(detected[0]!.isEncrypted);
  const id = detected[0]!.archiveId;

  await assert.rejects(() => rctrl.restore(id), PasswordRequiredError);
  await assert.rejects(() => rctrl.restore(id, 'wrong'), DecryptionError);
  const result = await rctrl.restore(id, 'pw');
  assert.equal(result.fileName, 'notes.txt');
  assert.deepEqual(result.data, multiCardData);
});

test('multi-archive detection groups by archive ID and dedups by UID', async () => {
  const a = await archiveToCards(multiCardData, { compress: false, fileName: 'a.bin' });
  const b = await archiveToCards(crypto.getRandomValues(new Uint8Array(900)), { compress: false, fileName: 'b.bin' });

  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);

  // Tap archive A's first card for real.
  rt.enqueueTag(new Uint8Array([1, 0, 0, 0]), a[0]!);
  let list = await rctrl.scanNextCard();

  // Re-tap the SAME UID, but this time the "card" on the reader holds a corrupted
  // payload (same archiveId/chunkIndex, flipped payload byte, stale CRC) -- MockTransport
  // stores card contents keyed by UID, so this really does replace what a later read of
  // that UID would return. If the UID dedup guard were removed, RestoreController would
  // read this and clobber chunk 0 of archive A's group, and assembly below would fail
  // with a CRC mismatch. With the guard, the second tap of an already-seen UID is never
  // read, so the group (and the eventual restore) is unaffected.
  const decoded0 = decodeChunk(a[0]!);
  const corrupted = encodeChunk({
    ...decoded0,
    payload: decoded0.payload.map((byte, i) => (i === 0 ? byte ^ 0xff : byte)),
  });
  rt.enqueueTag(new Uint8Array([1, 0, 0, 0]), corrupted);
  list = await rctrl.scanNextCard();

  // Now scan the rest of archive A and all of archive B.
  for (let i = 1; i < a.length; i++) {
    rt.enqueueTag(new Uint8Array([1, 0, 0, i]), a[i]!);
    list = await rctrl.scanNextCard();
  }
  for (let i = 0; i < b.length; i++) {
    rt.enqueueTag(new Uint8Array([2, 0, 0, i]), b[i]!);
    list = await rctrl.scanNextCard();
  }
  assert.equal(list.length, 2);
  assert.ok(list.every((d) => d.complete));

  const archiveA = list.find((d) => d.totalChunks === a.length)!;
  assert.equal(archiveA.isCompressed, false);
  assert.equal(archiveA.shortId.length, 8);
  const restored = await rctrl.restore(archiveA.archiveId);
  assert.equal(restored.fileName, 'a.bin');
  assert.deepEqual(restored.data, multiCardData);
});

test('restoring an incomplete archive throws', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, fileName: 'x.bin' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  // Enqueue all but the last card.
  for (let i = 0; i < stored.length - 1; i++) rt.enqueueTag(uid(i), stored[i]!);
  let list = await rctrl.scanNextCard();
  for (let i = 1; i < stored.length - 1; i++) list = await rctrl.scanNextCard();
  assert.ok(!list[0]!.complete);
  await assert.rejects(() => rctrl.restore(list[0]!.archiveId), NfarAssemblyError);
});

test('writeNextCard/scanNextCard reject with AbortError when the signal is already aborted', async () => {
  const controller = new AbortController();
  controller.abort();

  const t1 = new MockTransport();
  const actrl = new ArchiveController(t1);
  await actrl.prepare({ data: new Uint8Array([1, 2, 3]), fileName: 'x.bin', compress: false, payloadSize: 720 });
  await assert.rejects(
    () => actrl.writeNextCard(controller.signal),
    (e: unknown) => e instanceof DOMException && e.name === 'AbortError',
  );

  const t2 = new MockTransport();
  const rctrl = new RestoreController(t2);
  await assert.rejects(
    () => rctrl.scanNextCard(controller.signal),
    (e: unknown) => e instanceof DOMException && e.name === 'AbortError',
  );
});
