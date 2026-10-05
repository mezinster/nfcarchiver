import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { renderSlots, slotState, SLOT_GLYPHS, MAX_SLOTS } from '../app/ui/stage-view.js';
import { setLocale } from '../app/i18n/index.js';
import { en } from '../app/i18n/en.js';
import { pl } from '../app/i18n/pl.js';

/** Minimal DOM stub — the surface renderSlots touches (same shape as restore-view.test.ts). */
interface StubEl {
  tagName: string; className: string; textContent: string; innerHTML: string;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc; attrs: Record<string, string>;
  append(...kids: StubEl[]): void; appendChild(kid: StubEl): StubEl; remove(): void;
  setAttribute(name: string, value: string): void; getAttribute(name: string): string | null; removeAttribute(name: string): void;
}
interface StubDoc { createElement(tag: string): StubEl; }
function makeDoc(): StubDoc {
  const doc: StubDoc = {
    createElement(tag: string): StubEl {
      const el: StubEl = {
        tagName: tag.toUpperCase(), className: '', textContent: '', innerHTML: '',
        children: [], parent: null, ownerDocument: doc, attrs: {},
        append(...kids) { for (const k of kids) { k.parent = el; el.children.push(k); } },
        appendChild(kid) { kid.parent = el; el.children.push(kid); return kid; },
        remove() { if (el.parent) { el.parent.children.splice(el.parent.children.indexOf(el), 1); el.parent = null; } },
        setAttribute(name, value) { el.attrs[name] = value; },
        getAttribute(name) { return el.attrs[name] ?? null; },
        removeAttribute(name) { delete el.attrs[name]; },
      };
      return el;
    },
  };
  return doc;
}
const box = (): StubEl => makeDoc().createElement('div');
const render = (c: StubEl, w: number, n: number, warning = false) =>
  renderSlots(c as unknown as HTMLElement, w, n, { warning });
const states = (c: StubEl) => c.children.map((s) => s.getAttribute('data-state'));

test('slotState by position', () => {
  assert.equal(slotState(0, 1, 3, false), 'written');
  assert.equal(slotState(1, 1, 3, false), 'current');
  assert.equal(slotState(1, 1, 3, true), 'warning');
  assert.equal(slotState(2, 1, 3, true), 'waiting');
  assert.equal(slotState(2, 3, 3, false), 'written');
});

test('renders one slot per card, labelled, with states by position', () => {
  setLocale('en');
  const c = box();
  render(c, 1, 3);
  assert.deepEqual(states(c), ['written', 'current', 'waiting']);
  const [glyph, name, state] = c.children[1]!.children;
  assert.match(glyph!.innerHTML, /i-nfc/);
  assert.equal(name!.textContent, en.slotCard(2));
  assert.equal(state!.textContent, en.slotWriting);
  assert.equal(c.getAttribute('data-mode'), 'slots');
});

test('warning marks only the current slot', () => {
  const c = box();
  render(c, 1, 3, true);
  assert.deepEqual(states(c), ['written', 'warning', 'waiting']);
});

test('every slot is written when the archive is done', () => {
  const c = box();
  render(c, 3, 3);
  assert.deepEqual(states(c), ['written', 'written', 'written']);
});

test('reuses slots and follows a re-chunk in both directions', () => {
  const c = box();
  render(c, 0, 3);
  const first = c.children[0]!;
  render(c, 1, 5); // Auto-detect found a smaller card: more chunks
  assert.equal(c.children.length, 5);
  assert.strictEqual(c.children[0], first, 'slot 1 reconciled, not rebuilt');
  render(c, 1, 2); // …or a bigger one: fewer chunks
  assert.equal(c.children.length, 2);
  assert.deepEqual(states(c), ['written', 'current']);
});

test('marks rows above DENSE_ABOVE dense and switches to a counter above MAX_SLOTS', () => {
  setLocale('en');
  const c = box();
  render(c, 2, 6);
  assert.equal(c.getAttribute('data-dense'), '');
  render(c, 6, MAX_SLOTS + 14);
  assert.equal(c.children.length, 1);
  assert.equal(c.getAttribute('data-mode'), 'counter');
  assert.equal(c.children[0]!.textContent, en.cardOfTotal(7, 24));
  render(c, 0, 3);
  assert.equal(c.children.length, 3);
  assert.equal(c.getAttribute('data-mode'), 'slots');
  assert.equal(c.getAttribute('data-dense'), null);
});

test('relabels after a locale switch', () => {
  const c = box();
  setLocale('en');
  render(c, 0, 2);
  try {
    setLocale('pl');
    render(c, 0, 2);
    assert.equal(c.children[0]!.children[1]!.textContent, pl.slotCard(1));
    assert.equal(c.children[0]!.children[2]!.textContent, pl.slotWriting);
  } finally {
    setLocale('en');
  }
});

test('every slot glyph exists in the sprite', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app/index.html', import.meta.url)), 'utf8');
  for (const id of SLOT_GLYPHS) assert.ok(html.includes(`<symbol id="${id}"`), `sprite has no ${id}`);
});
