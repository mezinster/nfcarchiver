import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { decodeChunk, encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { ArchiveController, RestoreController, PasswordRequiredError, OverwriteRequiredError, RechunkTooLateError } from '../app/controller.js';
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

test('restore scan skips a blank/foreign card instead of ending the session', async () => {
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);

  // A valid single-chunk archive (real CRC so it also restores).
  const payload = new Uint8Array([1]);
  const good = encodeChunk({
    archiveId: new Uint8Array(16).fill(5), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  rt.enqueueTag(uid(0), good);
  let list = await rctrl.scanNextCard();
  assert.equal(list.length, 1);

  // A blank/foreign card (no NFAR bytes) — readChunk throws NfarFormatError.
  // It must be skipped, not thrown, so the scan session survives.
  rt.enqueueTag(uid(1));
  list = await rctrl.scanNextCard();
  assert.equal(list.length, 1); // the foreign card added no archive

  // Re-tapping the foreign card is deduped (no repeated read attempt).
  rt.enqueueTag(uid(1));
  list = await rctrl.scanNextCard();
  assert.equal(list.length, 1);

  // The good archive still restores.
  const result = await rctrl.restore(list[0]!.archiveId);
  assert.deepEqual([...result.data], [1]);
});

test('assembledPayload returns the pre-decrypt bytes for a detected group', async () => {
  const stored = await archiveToCards(multiCardData, { compress: false, fileName: 'x.bin' });
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((bytes, i) => rt.enqueueTag(uid(i), bytes));
  let list = await rctrl.scanNextCard();
  for (let i = 1; i < stored.length; i++) list = await rctrl.scanNextCard();
  assert.ok(list[0]!.complete);

  const payload = rctrl.assembledPayload(list[0]!.archiveId);
  // For a plain archive the assembled payload is the filename-wrapped plaintext,
  // so it decodes back to the original data via the restore path already tested.
  const result = await rctrl.restore(list[0]!.archiveId);
  assert.ok(payload.length >= result.data.length);
});

test('assembledPayload throws for an unknown archive id', () => {
  const rctrl = new RestoreController(new MockTransport());
  assert.throws(() => rctrl.assembledPayload('does-not-exist'));
});

test('rechunkForCapacity grows the chunk count for a smaller card and refuses after a write', async () => {
  const t = new MockTransport();
  t.maxChunkPayload = 73; // simulate an NTAG213-sized card so writeNextCard won't re-rechunk
  const ctrl = new ArchiveController(t);
  const big = await ctrl.prepare({ data: multiCardData, fileName: 'x.bin', compress: false, payloadSize: 720 });
  const small = ctrl.rechunkForCapacity(73);
  assert.ok(small > big, `expected more chunks after shrinking: ${small} > ${big}`);
  t.enqueueTag(uid(0));
  await ctrl.writeNextCard(); // 73 === current payloadSize -> no auto-rechunk; writes card 0
  assert.throws(() => ctrl.rechunkForCapacity(428), RechunkTooLateError);
});

test('writeNextCard auto-rechunks to the tapped card and still restores byte-identically', async () => {
  const t = new MockTransport();
  t.maxChunkPayload = 73; // the tapped card is much smaller than the selected NTAG216
  const ctrl = new ArchiveController(t);
  const originalTotal = await ctrl.prepare({ data: multiCardData, fileName: 'x.bin', compress: false, payloadSize: 812 });

  const stored: Uint8Array[] = [];
  let done = false, i = 0, guard = 0;
  let firstRechunk: { total: number; payloadSize: number } | undefined;
  while (!done && guard++ < 1000) {
    t.enqueueTag(uid(i));
    const res = await ctrl.writeNextCard();
    if (res.rechunkedTo && firstRechunk === undefined) firstRechunk = res.rechunkedTo;
    done = res.done;
    t.enqueueTag(uid(i)); await t.awaitTag(); stored.push(await t.readChunk()); // read back this card
    i++;
  }
  assert.ok(firstRechunk, 'the first tap reported a re-chunk');
  assert.equal(firstRechunk!.payloadSize, 73);
  assert.ok(firstRechunk!.total > originalTotal, `more, smaller cards: ${firstRechunk!.total} > ${originalTotal}`);
  assert.equal(stored.length, firstRechunk!.total);
  // all written cards share one archiveId (coherent archive)
  const ids = new Set(stored.map((b) => decodeChunk(b).archiveId.join(',')));
  assert.equal(ids.size, 1);

  // restore the small-card pile -> byte-identical to the original data
  const rt = new MockTransport();
  const rctrl = new RestoreController(rt);
  stored.forEach((b, j) => rt.enqueueTag(uid(j), b));
  let list = await rctrl.scanNextCard();
  for (let j = 1; j < stored.length; j++) list = await rctrl.scanNextCard();
  assert.ok(list[0]!.complete);
  const result = await rctrl.restore(list[0]!.archiveId);
  assert.deepEqual(result.data, multiCardData);
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

test('setTransport swaps the transport mid-session and preserves written state', async () => {
  const t1 = new MockTransport();
  const ctrl = new ArchiveController(t1);
  const total = await ctrl.prepare({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });
  assert.ok(total >= 3, `need >=3 cards, got ${total}`);

  // Write the first two cards on t1.
  t1.enqueueTag(uid(0)); await ctrl.writeNextCard();
  t1.enqueueTag(uid(1)); const afterTwo = await ctrl.writeNextCard();
  assert.equal(afterTwo.progress.written, 2);

  // Swap in a fresh transport; the controller must resume at chunk index 2.
  const t2 = new MockTransport();
  ctrl.setTransport(t2);
  t2.enqueueTag(uid(2));
  const afterSwap = await ctrl.writeNextCard();
  assert.equal(afterSwap.progress.written, 3, 'continues counting from the preserved state');

  // The chunk written on t2 is card index 2 (distinct UID, real NFAR bytes).
  t2.enqueueTag(uid(2)); await t2.awaitTag();
  const stored = decodeChunk(await t2.readChunk());
  assert.equal(stored.chunkIndex, 2, 'wrote the correct next chunk after the swap');
});
