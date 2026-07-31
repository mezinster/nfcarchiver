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
