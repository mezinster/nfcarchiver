import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * The UI resolves every control by id. A renamed or dropped id returns null and
 * fails silently at runtime — nothing else in the suite notices, because the
 * logic under test never touches the DOM.
 *
 * That gap made the UI refactor risky enough to be called out in its plan, so
 * it is closed here: every id the app looks up must exist in the markup.
 */

const appDir = new URL('../../app/', import.meta.url);
const html = readFileSync(fileURLToPath(new URL('index.html', appDir)), 'utf8');

function sourceFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: URL): void => {
    for (const entry of readdirSync(fileURLToPath(dir), { withFileTypes: true })) {
      const child = new URL(entry.name + (entry.isDirectory() ? '/' : ''), dir);
      if (entry.isDirectory()) walk(child);
      else if (entry.name.endsWith('.ts')) out.push(readFileSync(fileURLToPath(child), 'utf8'));
    }
  };
  walk(appDir);
  return out;
}

test('every id the app looks up exists in index.html', () => {
  const ids = new Set<string>();
  for (const src of sourceFiles()) {
    // The `$('…')` helper each panel defines, and direct getElementById calls.
    for (const m of src.matchAll(/\$\('([A-Za-z0-9_-]+)'\)/g)) ids.add(m[1]!);
    for (const m of src.matchAll(/getElementById\('([A-Za-z0-9_-]+)'\)/g)) ids.add(m[1]!);
  }
  assert.ok(ids.size > 20, `expected to find many ids, found ${ids.size} — the scan regex may be stale`);

  const missing = [...ids].filter((id) => !html.includes(`id="${id}"`)).sort();
  assert.deepEqual(missing, [], `index.html is missing id(s) the app resolves: ${missing.join(', ')}`);
});

test('the tab strip keeps the structure shell.ts queries', () => {
  // shell.ts binds via `#tabs button[data-tab="…"]` and sets aria-selected on
  // the result, so #tabs must stay the buttons' ancestor and each data-tab
  // value must survive. The five values are fixed by shell.ts's TABS tuple.
  const tabs = /<div id="tabs"[^>]*>([\s\S]*?)<\/div>/.exec(html);
  assert.ok(tabs, 'no #tabs container in index.html');
  for (const name of ['archive', 'restore', 'files', 'log', 'about']) {
    assert.match(tabs[1]!, new RegExp(`<button[^>]*data-tab="${name}"`),
      `#tabs is missing a button for data-tab="${name}"`);
    assert.ok(html.includes(`id="panel-${name}"`), `missing panel-${name}`);
  }
  assert.match(tabs[1]!, /aria-selected="true"/, 'no tab is initially selected');
});

/**
 * Two CSS invariants that only bite in a real browser, so nothing else in the
 * suite can catch them. Both were live bugs in the inspect dialog.
 *
 * Returns the author rules whose subject is a <dialog> element itself — not a
 * descendant (`dialog.inspect pre`) and not a pseudo-element (`dialog::backdrop`),
 * neither of which is the dialog box.
 */
function dialogSubjectRules(): Array<{ selector: string; body: string }> {
  const style = /<style>([\s\S]*?)<\/style>/.exec(html);
  assert.ok(style, 'no <style> block in index.html');
  const css = style[1]!
    .replace(/\/\*[\s\S]*?\*\//g, '')     // comments may contain example CSS
    .replace(/@media[^{]*\{/g, '');       // flatten, so rules inside are scanned too

  const out: Array<{ selector: string; body: string }> = [];
  for (const rule of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const body = rule[2]!;
    for (const selector of rule[1]!.split(',')) {
      // The subject is the last compound selector: what the rule actually styles.
      const subject = selector.trim().split(/[\s>+~]+/).pop() ?? '';
      if (/^dialog\b/.test(subject) && !subject.includes('::')) out.push({ selector: subject, body });
    }
  }
  assert.ok(out.length > 0, 'no dialog rules found — the CSS scan may be stale');
  return out;
}

test('no author rule sets display on a dialog that can be closed', () => {
  // Author CSS beats the UA sheet regardless of specificity, so `display` on a
  // bare `dialog…` selector also defeats `dialog:not([open]) { display: none }`.
  // The closed dialog then renders permanently as a ghost copy of itself, and
  // Close looks broken: it shuts a modal whose twin is still on screen.
  // Qualifying the selector with [open] is the escape hatch.
  const offenders = dialogSubjectRules()
    .filter((r) => /(^|[;\s])display\s*:/.test(r.body) && !r.selector.includes('[open]'))
    .map((r) => r.selector);
  assert.deepEqual(offenders, [],
    `these rules set display on a dialog without an [open] qualifier: ${offenders.join(', ')}`);
});

test('a dialog is never its own scroll container', () => {
  // A rounded box cannot clip its own scrollbar — Chromium paints the gutter
  // outside the border-radius clip, so a scrolling dialog goes square down its
  // right edge. An inner wrapper must scroll instead.
  const offenders = dialogSubjectRules()
    .filter((r) => /overflow(-[xy])?\s*:\s*(auto|scroll)/.test(r.body))
    .map((r) => r.selector);
  assert.deepEqual(offenders, [],
    `these rules let a dialog scroll itself, squaring its corners: ${offenders.join(', ')}`);
});

test('every icon referenced by <use> is defined in the sprite', () => {
  const defined = new Set([...html.matchAll(/<symbol id="([^"]+)"/g)].map((m) => m[1]!));
  const referenced = new Set<string>();
  for (const m of html.matchAll(/<use href="#([^"]+)"/g)) referenced.add(m[1]!);
  // The view builders inject icons from TypeScript, so scan those too.
  for (const src of sourceFiles()) {
    for (const m of src.matchAll(/<use href="#([^"]+)"/g)) referenced.add(m[1]!);
  }
  assert.ok(referenced.size > 0, 'no icons referenced — the scan regex may be stale');
  const undefinedIcons = [...referenced].filter((id) => !defined.has(id)).sort();
  assert.deepEqual(undefinedIcons, [], `<use> references undefined symbol(s): ${undefinedIcons.join(', ')}`);
});
