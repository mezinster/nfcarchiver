import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderArchiveList } from '../app/ui/restore-view.js';
import type { DetectedArchive } from '../app/controller.js';
import { setLocale } from '../app/i18n/index.js';
import { en } from '../app/i18n/en.js';
import { pl } from '../app/i18n/pl.js';

/**
 * Minimal DOM stub — just the surface renderArchiveList touches. Enough to
 * prove element identity is preserved across re-renders and that a click on a
 * reused button still fires its listener (the exact thing the real bug broke).
 */
interface StubEl {
  tagName: string;
  className: string;
  textContent: string;
  disabled: boolean;
  children: StubEl[];
  parent: StubEl | null;
  ownerDocument: StubDoc;
  attrs: Record<string, string>;
  listeners: Record<string, Array<() => void>>;
  append(...kids: StubEl[]): void;
  appendChild(kid: StubEl): StubEl;
  remove(): void;
  setAttribute(name: string, value: string): void;
  getAttribute(name: string): string | null;
  addEventListener(type: string, fn: () => void): void;
  click(): void;
}
interface StubDoc { createElement(tag: string): StubEl; }

function makeDoc(): StubDoc {
  const doc: StubDoc = {
    createElement(tag: string): StubEl {
      const el: StubEl = {
        tagName: tag.toUpperCase(), className: '', textContent: '', disabled: false,
        children: [], parent: null, ownerDocument: doc, attrs: {}, listeners: {},
        append(...kids) { for (const k of kids) { k.parent = el; el.children.push(k); } },
        appendChild(kid) { kid.parent = el; el.children.push(kid); return kid; },
        remove() { if (el.parent) { el.parent.children.splice(el.parent.children.indexOf(el), 1); el.parent = null; } },
        setAttribute(name, value) { el.attrs[name] = value; },
        getAttribute(name) { return el.attrs[name] ?? null; },
        addEventListener(type, fn) { (el.listeners[type] ??= []).push(fn); },
        click() { for (const fn of el.listeners['click'] ?? []) fn(); },
      };
      return el;
    },
  };
  return doc;
}

const archive = (over: Partial<DetectedArchive>): DetectedArchive => ({
  archiveId: '16312c0b-0000-0000-0000-000000000000', shortId: '16312c0b',
  totalChunks: 1, received: 1, isEncrypted: false, isCompressed: false, complete: true, ...over,
});

test('restore view reuses button elements across identical re-renders (a click is never lost)', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const picks: string[] = [];
  const list = [archive({})];

  renderArchiveList(container, list, (id) => picks.push(id));
  const firstBtn = (container as unknown as StubEl).children[0]!.children[1]!;

  // A card resting on the reader makes the scan loop re-render the SAME list
  // dozens of times a second. The button the user is about to click must not be
  // torn down and replaced underneath them.
  renderArchiveList(container, list, (id) => picks.push(id));
  const secondBtn = (container as unknown as StubEl).children[0]!.children[1]!;

  assert.strictEqual(firstBtn, secondBtn, 'Restore button must be reused, not recreated');
  secondBtn.click();
  assert.deepEqual(picks, ['16312c0b-0000-0000-0000-000000000000']);
});

test('restore view disables the button for an incomplete archive and enables it once complete', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const id = 'a71a4318-0000-0000-0000-000000000000';

  renderArchiveList(container, [archive({ archiveId: id, shortId: 'a71a4318', totalChunks: 6, received: 3, complete: false })], () => {});
  const btn = (container as unknown as StubEl).children[0]!.children[1]!;
  assert.equal(btn.disabled, true, 'incomplete archive button is disabled');

  // Last chunks arrive: same archive id, now complete -> same button, re-enabled.
  renderArchiveList(container, [archive({ archiveId: id, shortId: 'a71a4318', totalChunks: 6, received: 6, complete: true })], () => {});
  assert.strictEqual((container as unknown as StubEl).children[0]!.children[1]!, btn, 'same row/button reused');
  assert.equal(btn.disabled, false, 'completed archive button is enabled');
});

// Regression: the Restore label was set only when the row was created, so a
// language switch left it frozen in the boot language while the row's own text
// changed around it.
test('restore view re-labels the Restore button after a language switch', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const list = [archive({})];
  setLocale('en');
  try {
    renderArchiveList(container, list, () => {});
    const btn = (container as unknown as StubEl).children[0]!.children[1]!;
    assert.equal(btn.textContent, en.restore);

    setLocale('pl');
    renderArchiveList(container, list, () => {});
    assert.strictEqual((container as unknown as StubEl).children[0]!.children[1]!, btn, 'button must be reused');
    assert.equal(btn.textContent, pl.restore);
  } finally {
    setLocale('en');
  }
});

test('restore view drops rows for archives no longer in the list', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  const a = archive({ archiveId: 'aaaa', shortId: 'aaaa' });
  const b = archive({ archiveId: 'bbbb', shortId: 'bbbb' });

  renderArchiveList(container, [a, b], () => {});
  assert.equal((container as unknown as StubEl).children.length, 2);

  renderArchiveList(container, [a], () => {});
  assert.equal((container as unknown as StubEl).children.length, 1);
  assert.equal((container as unknown as StubEl).children[0]!.getAttribute('data-archive-id'), 'aaaa');
});
