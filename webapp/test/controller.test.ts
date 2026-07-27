import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { encodeChunk } from '../src/chunk.js';
import { ArchiveController, RestoreController, PasswordRequiredError, OverwriteRequiredError, WrongArchiveError } from '../app/controller.js';
import { DecryptionError } from '../src/crypto.js';

const uid = (n: number) => new Uint8Array([0xa0, 0, 0, n]);
// Random 2000 bytes: incompressible, so with compress:false it reliably needs
// multiple 720-byte cards (ceil(2000/720) = 3 chunks).
const multiCardData = crypto.getRandomValues(new Uint8Array(2000));

test('archive writes each card once and reports progress', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, compress: false });
  assert.ok(total >= 2, `expected multiple cards, got ${total}`);
  for (let i = 0; i < total; i++) t.enqueueTag(uid(i));
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await ctrl.writeNextCard());
  assert.ok(done);
});

test('archive skips a re-tapped card it already wrote', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  const total = await ctrl.prepare({ data: multiCardData, compress: false });
  assert.ok(total >= 2);
  t.enqueueTag(uid(0));
  const first = await ctrl.writeNextCard();
  assert.equal(first.progress.written, 1);
  t.enqueueTag(uid(0)); // same card again -> must be skipped, not double-counted
  const repeat = await ctrl.writeNextCard();
  assert.equal(repeat.progress.written, 1);
  assert.equal(repeat.done, false);
});

test('archive requires explicit confirmation to overwrite an NFAR card', async () => {
  const t = new MockTransport();
  const ctrl = new ArchiveController(t);
  await ctrl.prepare({ data: multiCardData, compress: false });
  // A card already carrying NFAR bytes -> peekIsNfar() is true.
  const existingNfar = encodeChunk({
    archiveId: new Uint8Array(16).fill(1), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  t.enqueueTag(uid(7), existingNfar);
  await assert.rejects(() => ctrl.writeNextCard(undefined, false), OverwriteRequiredError);
  t.enqueueTag(uid(7), existingNfar);
  const ok = await ctrl.writeNextCard(undefined, true); // confirmed -> proceeds
  assert.equal(ok.progress.written, 1);
});

test('restore collects chunks and demands a password when encrypted', async () => {
  // Archive to a source transport, capture each card's stored bytes.
  const src = new MockTransport();
  const actrl = new ArchiveController(src);
  const total = await actrl.prepare({ data: multiCardData, compress: false, password: 'pw' });
  assert.ok(total >= 2);
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i));
    await actrl.writeNextCard();
    src.enqueueTag(uid(i));
    await src.awaitTag();
    stored.push(await src.readChunk());
  }

  // Restore from a fresh transport preloaded with those cards.
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  for (let i = 0; i < total; i++) rt.enqueueTag(uid(i), stored[i]!);
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await rctrl.scanNextCard());
  assert.ok(done);
  await assert.rejects(() => rctrl.finish(), PasswordRequiredError);
  assert.deepEqual(await rctrl.finish('pw'), multiCardData);
});

test('restore rejects a card from a different archive', async () => {
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  const chunkA = encodeChunk({
    archiveId: new Uint8Array(16).fill(1), totalChunks: 2, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  const chunkB = encodeChunk({
    archiveId: new Uint8Array(16).fill(2), totalChunks: 2, chunkIndex: 1,
    payload: new Uint8Array([2]), crc32: 0, flags: 0,
  });
  rt.enqueueTag(uid(0), chunkA);
  const first = await rctrl.scanNextCard();
  assert.equal(first.collected, 1);
  rt.enqueueTag(uid(1), chunkB);
  await assert.rejects(() => rctrl.scanNextCard(), WrongArchiveError);
});

test('finish() is safely retryable after a wrong password', async () => {
  const src = new MockTransport();
  const actrl = new ArchiveController(src);
  const total = await actrl.prepare({ data: multiCardData, compress: false, password: 'pw' });
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i));
    await actrl.writeNextCard();
    src.enqueueTag(uid(i));
    await src.awaitTag();
    stored.push(await src.readChunk());
  }

  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  for (let i = 0; i < total; i++) rt.enqueueTag(uid(i), stored[i]!);
  let done = false, guard = 0;
  while (!done && guard++ < 50) ({ done } = await rctrl.scanNextCard());
  assert.ok(done);
  await assert.rejects(() => rctrl.finish('wrong'), DecryptionError);
  assert.deepEqual(await rctrl.finish('pw'), multiCardData);
});

test('writeNextCard/scanNextCard reject with AbortError when the signal is already aborted', async () => {
  const controller = new AbortController();
  controller.abort();

  const t1 = new MockTransport();
  const actrl = new ArchiveController(t1);
  await actrl.prepare({ data: new Uint8Array([1, 2, 3]), compress: false });
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
