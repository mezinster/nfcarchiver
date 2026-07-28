import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderFileList, humanSize } from '../app/ui/files-view.js';
import type { FileListItem } from '../src/storage/file-store.js';

interface StubEl {
  tagName: string; className: string; textContent: string; disabled: boolean;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc;
  attrs: Record<string, string>; listeners: Record<string, Array<() => void>>;
  append(...k: StubEl[]): void; appendChild(k: StubEl): StubEl; remove(): void;
  setAttribute(n: string, v: string): void; getAttribute(n: string): string | null;
  addEventListener(t: string, fn: () => void): void; click(): void;
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
        click() { for (const fn of el.listeners['click'] ?? []) fn(); },
      };
      return el;
    },
  };
  return doc;
}

const item = (over: Partial<FileListItem>): FileListItem => ({
  id: 'id-1', name: 'a.bin', size: 3, createdAt: 1000,
  isEncrypted: false, isCompressed: false, totalChunks: 1, ...over,
});

test('humanSize formats bytes/KB/MB', () => {
  assert.equal(humanSize(0), '0 B');
  assert.equal(humanSize(512), '512 B');
  assert.equal(humanSize(1536), '1.5 KB');
  assert.equal(humanSize(2 * 1024 * 1024), '2.0 MB');
});

test('renderFileList reuses row buttons across identical re-renders', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const files = [item({})];
  renderFileList(container, files, { onDownload: () => {}, onDelete: () => {} });
  const firstRow = (container as unknown as StubEl).children[0]!;
  renderFileList(container, files, { onDownload: () => {}, onDelete: () => {} });
  assert.strictEqual((container as unknown as StubEl).children[0]!, firstRow, 'row reused');
});

test('renderFileList wires Download and Delete to the row id', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const dl: string[] = []; const del: string[] = [];
  renderFileList(container, [item({ id: 'x' })], { onDownload: (id) => dl.push(id), onDelete: (id) => del.push(id) });
  const row = (container as unknown as StubEl).children[0]!;
  row.children[1]!.click(); // Download
  row.children[2]!.click(); // Delete
  assert.deepEqual(dl, ['x']);
  assert.deepEqual(del, ['x']);
});

test('renderFileList drops rows for files no longer present', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const a = item({ id: 'a' }); const b = item({ id: 'b' });
  renderFileList(container, [a, b], { onDownload: () => {}, onDelete: () => {} });
  assert.equal((container as unknown as StubEl).children.length, 2);
  renderFileList(container, [a], { onDownload: () => {}, onDelete: () => {} });
  assert.equal((container as unknown as StubEl).children.length, 1);
  assert.equal((container as unknown as StubEl).children[0]!.getAttribute('data-file-id'), 'a');
});
