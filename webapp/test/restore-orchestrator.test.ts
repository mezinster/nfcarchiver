import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockTransport } from '../src/transport/mock-transport.js';
import { ArchiveController } from '../app/controller.js';
import { RestoreOrchestrator, type RestoreIO } from '../app/ui/restore-orchestrator.js';
import { Logger } from '../src/log/logger.js';

/** Minimal DOM stub (as in restore-view.test.ts) — but click() is async and
 *  awaits handler return values, so a button click that triggers an async
 *  restore can be awaited deterministically in the test. */
interface StubEl {
  tagName: string; className: string; textContent: string; disabled: boolean;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc;
  attrs: Record<string, string>; listeners: Record<string, Array<() => unknown>>;
  append(...k: StubEl[]): void; appendChild(k: StubEl): StubEl; remove(): void;
  setAttribute(n: string, v: string): void; getAttribute(n: string): string | null;
  addEventListener(t: string, fn: () => unknown): void; click(): Promise<void>;
}
interface StubDoc { createElement(tag: string): StubEl; }
function makeDoc(): StubDoc {
  const doc: StubDoc = {
    createElement(tag) {
      const el: StubEl = {
        tagName: tag.toUpperCase(), className: '', textContent: '', disabled: false,
        children: [], parent: null, ownerDocument: doc, attrs: {}, listeners: {},
        append(...k) { for (const c of k) { c.parent = el; el.children.push(c); } },
        appendChild(k) { k.parent = el; el.children.push(k); return k; },
        remove() { if (el.parent) { el.parent.children.splice(el.parent.children.indexOf(el), 1); el.parent = null; } },
        setAttribute(n, v) { el.attrs[n] = v; },
        getAttribute(n) { return el.attrs[n] ?? null; },
        addEventListener(t, fn) { (el.listeners[t] ??= []).push(fn); },
        async click() { for (const fn of el.listeners['click'] ?? []) await fn(); },
      };
      return el;
    },
  };
  return doc;
}

const uidFor = (a: number) => (i: number) => new Uint8Array([a, 0, 0, i]);

/** Archive `data` to mock cards and return the stored bytes per card. */
async function archiveToCards(data: Uint8Array, opts: { compress: boolean; password?: string; fileName: string }): Promise<Uint8Array[]> {
  const src = new MockTransport();
  const ctrl = new ArchiveController(src);
  const uid = uidFor(0xa0);
  const total = await ctrl.prepare({ data, fileName: opts.fileName, compress: opts.compress, password: opts.password, payloadSize: 720 });
  const stored: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    src.enqueueTag(uid(i)); await ctrl.writeNextCard();
    src.enqueueTag(uid(i)); await src.awaitTag(); stored.push(await src.readChunk());
  }
  return stored;
}

function makeIO(container: StubEl, over?: Partial<RestoreIO>) {
  const downloads: Array<{ data: Uint8Array; name: string }> = [];
  const saved: Array<{ id: string; isEncrypted: boolean }> = [];
  const io: RestoreIO = {
    container: container as unknown as HTMLElement,
    files: { async saveRestored(e) { saved.push({ id: e.id, isEncrypted: e.isEncrypted }); } },
    promptPassword: () => null,
    download: (data, name) => downloads.push({ data, name }),
    fallbackName: () => 'restored.bin',
    setFileName: () => {},
    setStatus: () => {},
    log: new Logger(),
    ...over,
  };
  return { io, downloads, saved };
}

const signal = () => new AbortController().signal;

test('restore works for multiple archives, repeatedly, independent of the scan loop', async () => {
  const plain = crypto.getRandomValues(new Uint8Array(1500));   // multi-card, incompressible
  const secret = crypto.getRandomValues(new Uint8Array(1500));
  const cardsA = await archiveToCards(plain, { compress: false, fileName: 'a.bin' });
  const cardsB = await archiveToCards(secret, { compress: false, password: 'pw', fileName: 'b.bin' });

  const doc = makeDoc();
  const container = doc.createElement('div');
  const { io, downloads, saved } = makeIO(container, { promptPassword: () => 'pw' });
  const orch = new RestoreOrchestrator(io);

  const rt = new MockTransport();
  orch.startSession(rt);
  cardsA.forEach((b, i) => rt.enqueueTag(new Uint8Array([1, 0, 0, i]), b));
  cardsB.forEach((b, i) => rt.enqueueTag(new Uint8Array([2, 0, 0, i]), b));
  // Drive detection deterministically (MockTransport.awaitTag throws when idle,
  // so we never run the panel's unbounded loop).
  for (let i = 0; i < cardsA.length + cardsB.length; i++) await orch.scanStep(signal());

  const rows = (container as unknown as StubEl).children;
  assert.equal(rows.length, 2, 'both archives detected as rows');
  const btn = (rowIdx: number) => rows[rowIdx]!.children[1]!; // [span, Restore button]

  // Click archive A's Restore button -> restores the plain archive.
  await btn(0).click();
  assert.equal(downloads.length, 1);
  assert.deepEqual(downloads[0]!.data, plain);
  assert.equal(downloads[0]!.name, 'a.bin');

  // Click archive B's button -> encrypted, promptPassword supplies 'pw'.
  await btn(1).click();
  assert.equal(downloads.length, 2);
  assert.deepEqual(downloads[1]!.data, secret);

  // Regression: click archive A AGAIN -> restores a second time (the pre-fix
  // one-shot handler restored only once; a dead re-click would leave length 2).
  await btn(0).click();
  assert.equal(downloads.length, 3);
  assert.deepEqual(downloads[2]!.data, plain);

  // Restore-after-"stop": no scanStep in between, direct call still works.
  await orch.restoreArchive(rows[1]!.getAttribute('data-archive-id')!);
  assert.equal(downloads.length, 4);
  assert.deepEqual(downloads[3]!.data, secret);

  assert.ok(saved.some((s) => !s.isEncrypted) && saved.some((s) => s.isEncrypted), 'both saved to history');
});

test('restoreArchive ignores a wrong-then-cancelled password without downloading', async () => {
  const secret = crypto.getRandomValues(new Uint8Array(800));
  const cards = await archiveToCards(secret, { compress: false, password: 'pw', fileName: 's.bin' });
  const doc = makeDoc();
  const container = doc.createElement('div');
  // First prompt returns a wrong password, second returns null (cancel).
  const answers = ['nope', null] as Array<string | null>;
  const { io, downloads } = makeIO(container, { promptPassword: () => answers.shift() ?? null });
  const orch = new RestoreOrchestrator(io);
  const rt = new MockTransport();
  orch.startSession(rt);
  cards.forEach((b, i) => rt.enqueueTag(new Uint8Array([3, 0, 0, i]), b));
  for (let i = 0; i < cards.length; i++) await orch.scanStep(signal());
  await (container as unknown as StubEl).children[0]!.children[1]!.click();
  assert.equal(downloads.length, 0, 'cancelled restore downloads nothing');
});
