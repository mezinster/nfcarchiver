# Webapp Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate the webapp UI into the same seven languages the Flutter app supports (en, ru, tr, uk, ka, pl, be), with browser-locale auto-detection and a manual override.

**Architecture:** A new `app/i18n/` layer holds seven typed catalogues. `en.ts` is the schema — every other locale is annotated `: Messages`, so `tsc` refuses to build until all seven are complete. Static markup is translated through `data-i18n` attributes; dynamic strings read `t.key` at render time; `humanError()` is the single seam through which every core error is translated. `src/` is never modified.

**Tech Stack:** TypeScript 5.5 (strict, `noUncheckedIndexedAccess`), esbuild bundling, `node --test`, `Intl.PluralRules` (platform built-in, no new dependency).

**Source spec:** `docs/superpowers/specs/2026-07-30-webapp-localization-design.md`

## Global Constraints

- **Node ≥ 22.** Every command in this plan must be preceded by `source ~/.nvm/nvm.sh && nvm use --lts` — the shell default is Node 14.
- **Always `rm -rf dist && npm test`**, never bare `npm test`. The `tsc && node --test` chain does not clean stale compiled tests, and a deleted or renamed test keeps passing from `dist/`.
- **All commands run from `webapp/`.**
- **No new runtime dependencies.** `chameleon-ultra.js` remains the only one, importable ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`.
- **Dependency fence, both directions:** `app/i18n/` imports nothing from `src/`; `src/` imports nothing from `app/`. The core stays dependency-free and English-only.
- **`src/` is not modified by any task in this plan.** This includes `src/inspect/*`, which generates the card-inspection report body — that text stays English by design, like the Log tab.
- **Log strings stay English.** No `log.debug/info/warn/error` call site may route its message through `t`.
- **Never capture `t` at module scope.** `t` is a live ESM binding reassigned on language change. `t.key` read inside a function is correct; `const { tabArchive } = t` or a module-level `const SECTIONS = [t.x]` snapshots the old language and is a bug.
- **Commit style:** `feat(webapp): …` / `test(webapp): …`, one commit per task.

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `app/i18n/plural.ts` | `pr()` plural selection + the active plural locale. Separate module to avoid a cycle with `index.ts`. |
| `app/i18n/en.ts` | The English catalogue. Exports `en` and `type Messages = typeof en`. This is the schema. |
| `app/i18n/index.ts` | `SUPPORTED`, `pickLocale()`, the live `t` binding, `setLocale()`, `onLocaleChange()`, `initI18n()`. |
| `app/i18n/dom.ts` | `applyStaticText()` — the `data-i18n` walker. |
| `app/i18n/ru.ts` `uk.ts` `be.ts` `pl.ts` `tr.ts` `ka.ts` | The six translations. |
| `test/i18n.test.ts` | Plural, detection, catalogue parity, markup drift. |

**Modified:** `app/index.html` (attributes + language `<select>`), `app/main.ts` (call `initI18n` first), `app/ui/shell.ts` (selector wiring), `app/ui/errors.ts`, `app/ui/device.ts`, `app/ui/about-panel.ts`, `app/ui/archive-panel.ts`, `app/ui/archive-orchestrator.ts`, `app/ui/restore-panel.ts`, `app/ui/restore-orchestrator.ts`, `app/ui/restore-view.ts`, `app/ui/files-panel.ts`, `app/ui/files-view.ts`, `app/ui/inspect-orchestrator.ts`.

**Task order rationale:** the English refactor (Tasks 1–7) completes and freezes the key set before any translation is written (Tasks 8–9). `app/i18n/index.ts` starts with only `en` in its catalogue map and each translation task adds one import, so the build is green at every commit.

---

### Task 1: Plural helper

**Files:**
- Create: `webapp/app/i18n/plural.ts`
- Test: `webapp/test/i18n.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `pr(n: number, forms: PluralForms): string`, `setPluralLocale(locale: string): void`, `type PluralForms`.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/i18n.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pr, setPluralLocale } from '../app/i18n/plural.js';

test('pr selects English one/other', () => {
  setPluralLocale('en');
  const forms = { one: 'card', other: 'cards' };
  assert.equal(pr(1, forms), 'card');
  assert.equal(pr(0, forms), 'cards');
  assert.equal(pr(2, forms), 'cards');
  assert.equal(pr(11, forms), 'cards');
});

test('pr selects Russian one/few/many', () => {
  setPluralLocale('ru');
  const forms = { one: 'карта', few: 'карты', many: 'карт', other: 'карт' };
  assert.equal(pr(1, forms), 'карта');
  assert.equal(pr(2, forms), 'карты');
  assert.equal(pr(4, forms), 'карты');
  assert.equal(pr(5, forms), 'карт');
  assert.equal(pr(11, forms), 'карт');
  assert.equal(pr(21, forms), 'карта');
});

test('pr falls back to other when a category is absent', () => {
  setPluralLocale('ru');
  assert.equal(pr(2, { one: 'a', other: 'z' }), 'z');
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — `tsc` errors with "Cannot find module '../app/i18n/plural.js'".

- [ ] **Step 3: Write the implementation**

Create `webapp/app/i18n/plural.ts`:

```ts
/**
 * CLDR plural selection for the catalogues. Lives in its own module rather
 * than in index.ts because the catalogues import `pr` and index.ts imports the
 * catalogues — putting it in index.ts would be a circular import.
 */

/** Whatever categories the runtime's Intl reports ('one' | 'few' | … ). Derived
 *  from the platform type so it stays correct across TypeScript lib versions. */
type Category = ReturnType<Intl.PluralRules['select']>;

/** `other` is mandatory: it is the fallback for any category a locale omits. */
export type PluralForms = Partial<Record<Category, string>> & { other: string };

let selector = new Intl.PluralRules('en');

export function setPluralLocale(locale: string): void {
  selector = new Intl.PluralRules(locale);
}

export function pr(n: number, forms: PluralForms): string {
  return forms[selector.select(n)] ?? forms.other;
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS — the three new tests plus all 202 existing tests.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/i18n/plural.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): CLDR plural helper for localization"
```

---

### Task 2: English catalogue

**Files:**
- Create: `webapp/app/i18n/en.ts`
- Test: `webapp/test/i18n.test.ts` (append)

**Interfaces:**
- Consumes: `pr`, `PluralForms` from Task 1.
- Produces: `export const en`, `export type Messages = typeof en`. Every later task references these key names exactly as written below.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/i18n.test.ts`:

```ts
import { en, type Messages } from '../app/i18n/en.js';

test('English catalogue has no empty values', () => {
  for (const [key, value] of Object.entries(en)) {
    if (typeof value === 'string') assert.notEqual(value, '', `${key} is empty`);
  }
});

test('English catalogue function entries render', () => {
  setPluralLocale('en');
  assert.equal(en.tapCardOf(1, 8), 'Tap card 1 of 8 on the reader…');
  assert.equal(en.cardEstimate(1, false), '≈ 1 card');
  assert.equal(en.cardEstimate(3, true), '≈ 3 cards (est.) — adapts to the tapped card');
  assert.equal(en.archiveDone(1), 'Done — wrote and verified 1 card.');
  assert.equal(en.clearedFiles(2), 'Cleared 2 files.');
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — "Cannot find module '../app/i18n/en.js'".

- [ ] **Step 3: Write the implementation**

Create `webapp/app/i18n/en.ts`. **Do not add `as const`** — it would narrow every value to a string literal type and make the six translations fail to compile.

```ts
/**
 * The English catalogue, and the schema every other locale is checked against.
 *
 * Deliberately NOT `as const`: literal types here would force every translation
 * to repeat the English string verbatim to satisfy `: Messages`.
 *
 * Entries are functions wherever a value is interpolated, so each locale
 * controls its own word order.
 */
import { pr } from './plural.js';

export const en = {
  // — shell / device bar —
  connect: 'Connect Chameleon',
  inspectCard: 'Inspect card',
  themeToggle: 'Toggle light/dark',
  language: 'Language',
  statusConnected: 'connected',
  statusDisconnected: 'disconnected',
  connectedDot: 'Connected.',
  readerDisconnectedClickConnect: 'Reader disconnected — click Connect to resume.',

  // — tabs —
  tabArchive: 'Archive',
  tabRestore: 'Restore',
  tabFiles: 'Files',
  tabLog: 'Log',
  tabAbout: 'About',

  // — archive tab —
  orText: 'or text:',
  textPlaceholder: 'Type text to archive as text_note.txt',
  targetTag: 'target tag',
  targetAuto: 'Auto-detect (adapts to the card)',
  compress: 'compress',
  password: 'password',
  optionalPlaceholder: '(optional)',
  archiveToCards: 'Archive to cards',
  archiveIdle: 'Connect a Chameleon, then choose a file or type text.',
  archiveReady: 'Choose a file or type text, then Archive to cards.',
  archivePickFirst: 'Pick a file or type some text first.',
  cardEstimate: (n: number, isAuto: boolean) =>
    `≈ ${n} ${pr(n, { one: 'card', other: 'cards' })}${isAuto ? ' (est.) — adapts to the tapped card' : ''}`,

  // — archive write loop —
  progressDone: (written: number, total: number) => `✓ ${written} of ${total} cards written & verified`,
  progressWriting: (written: number, total: number) => `✓ ${written} of ${total} written & verified — tap the next card`,
  archiveDone: (n: number) => `Done — wrote and verified ${n} ${pr(n, { one: 'card', other: 'cards' })}.`,
  tapCardOf: (i: number, total: number) => `Tap card ${i} of ${total} on the reader…`,
  readerDisconnectedResume: 'Reader disconnected — reconnect to resume.',
  rechunked: (payloadSize: number, total: number) =>
    `Card holds ${payloadSize} B/chunk — writing ${total} ${pr(total, { one: 'card', other: 'cards' })} instead.`,
  noCardTapHold: 'No card detected — tap a card (hold it a few mm off)…',
  unsupportedTapOther: 'Unsupported tag — tap a Mifare Classic 1K or NTAG.',
  skippedTapDifferent: 'Skipped. Tap a different card…',
  retryAfter: (message: string) => `${message} — re-tap to retry.`,

  // — overwrite dialog —
  overwrite: 'Overwrite',
  overwriteAll: 'Overwrite all remaining',
  skip: 'Skip',

  // — restore tab —
  scanCards: 'Scan cards',
  stop: 'Stop',
  saveAs: 'save as',
  restoreIdle: 'Connect a Chameleon, then scan a pile of cards.',
  restoreReady: 'Scan a pile of cards to detect archives.',
  scanning: 'Scanning — tap cards on the reader…',
  tapMoreCards: 'Tap more cards, or Restore a complete one.',
  skippedCard: (message: string) => `Skipped a card: ${message}`,
  restore: 'Restore',
  encrypted: '🔒 encrypted',
  unencrypted: 'unencrypted',
  archiveRow: (shortId: string, isEncrypted: boolean, received: number, total: number, complete: boolean) =>
    `Archive ${shortId}…  ${isEncrypted ? '🔒 encrypted' : 'unencrypted'}  ·  ${received} / ${total} ${pr(total, { one: 'card', other: 'cards' })}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes: number, name: string) => `Restored ${bytes} bytes → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'This archive is encrypted. Enter password:',
  promptFileEncrypted: 'This file is encrypted. Enter password:',
  promptWrongPassword: 'Wrong password. Enter password:',
  tooManyPasswordAttempts: 'Too many failed password attempts.',
  cancelled: 'Cancelled.',

  // — files tab —
  filesEmpty: "No restored files yet. Restore an archive and it'll appear here.",
  clearAll: 'Clear all',
  confirmClearAll: 'Delete all stored files? This cannot be undone.',
  download: 'Download',
  deleteBtn: 'Delete',
  plain: 'plain',
  filesInfo: (count: number, size: string) =>
    `${count} ${pr(count, { one: 'file', other: 'files' })} · ${size} stored`,
  clearedFiles: (n: number) => `Cleared ${n} ${pr(n, { one: 'file', other: 'files' })}.`,
  downloadedTo: (size: string, name: string) => `Downloaded ${size} → ${name}.`,
  fileRow: (name: string, size: string, when: string, isEncrypted: boolean, totalChunks: number) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 encrypted' : 'plain'}  ·  ${totalChunks} ${pr(totalChunks, { one: 'card', other: 'cards' })}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'level',
  autoScroll: 'auto-scroll',
  mirrorToConsole: 'mirror to console',
  clear: 'Clear',
  copy: 'Copy',

  // — inspect dialog —
  close: 'Close',
  inspectIdentity: 'Identity',
  inspectNfar: 'NFAR chunk',
  inspectRaw: 'Raw',
  inspectHoldStill: 'Hold the card still on the reader…',
  inspectReading: (done: number, total: number) => `reading… ${done}/${total}`,
  inspectRead: (done: number, total: number) => `${done}/${total} read`,
  inspectStopped: 'Stopped.',
  inspectCardLost: 'Card left the field — re-tap and inspect again.',
  inspectDone: 'Done.',

  // — about tab —
  aboutWebVersion: (version: string, sha: string) => `Web version ${version} (${sha})`,
  aboutDescription: 'A distributed data archive system using NFC tags. Store files across multiple tags and restore them later — fully in your browser.',
  aboutSupportedHeading: 'Supported tags',
  aboutSupportedBody: 'Mifare Classic 1K and NTAG213/215/216, via a Chameleon Ultra over Web Bluetooth.',
  aboutWebNfcNote: '(Writing NTAG with the phone’s own NFC — no Chameleon — will come with the future Web NFC support.)',
  aboutPrivacyHeading: 'Privacy',
  aboutPrivacyBody: 'Everything runs client-side. Your files, text, and passwords never leave the browser — there is no server, no upload, and no tracking.',
  aboutLicensesHeading: 'Open-source licenses',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Card keys are not factory defaults — this card cannot be used.',
  errCardRead: 'Card read was incomplete — hold the card steady on the reader and tap again.',
  errWriteVerify: 'Write verification failed — move the card closer and retry.',
  errCardCapacity: 'This card is smaller than the ones already written — use cards of the same type, or restart the archive.',
  errTagTimeout: 'No card detected — tap a card on the reader.',
  errNfarFormat: 'This card holds no NFAR archive data.',
  errOverwriteRequired: 'This card already holds data.',
  errPasswordRequired: 'This archive is encrypted — enter a password.',
  errWrongPassword: 'Wrong password.',
  errUnsupportedTag: 'Unsupported tag — use a Mifare Classic 1K or NTAG213/215/216.',
  errNdefFormat: 'This tag holds no NFAR NDEF data.',
};

export type Messages = typeof en;
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/i18n/en.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): English message catalogue and Messages schema"
```

---

### Task 3: Locale registry, detection, and switching

**Files:**
- Create: `webapp/app/i18n/index.ts`
- Test: `webapp/test/i18n.test.ts` (append)

**Interfaces:**
- Consumes: `en`, `Messages` (Task 2); `setPluralLocale` (Task 1).
- Produces: `SUPPORTED: readonly Locale[]`, `type Locale`, `pickLocale(preferred: readonly string[]): Locale`, `let t: Messages`, `getLocale(): Locale`, `setLocale(l: Locale): void`, `onLocaleChange(fn: () => void): () => void`, `initI18n(): void`.

**Critical:** nothing at module top level may touch `navigator`, `document`, or `localStorage` — `test/i18n.test.ts` imports this module under Node. Browser access happens only inside `initI18n()`, which `app/main.ts` calls.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/i18n.test.ts`:

```ts
import { pickLocale, SUPPORTED, getLocale, setLocale, onLocaleChange, t } from '../app/i18n/index.js';

test('pickLocale matches primary subtags, case-insensitively', () => {
  assert.equal(pickLocale(['ru-RU', 'en']), 'ru');
  assert.equal(pickLocale(['RU']), 'ru');
  assert.equal(pickLocale(['pl-PL']), 'pl');
  assert.equal(pickLocale(['ka']), 'ka');
});

test('pickLocale falls back to English', () => {
  assert.equal(pickLocale(['ja', 'zh-Hant']), 'en');
  assert.equal(pickLocale([]), 'en');
});

test('pickLocale prefers the earliest supported entry', () => {
  assert.equal(pickLocale(['ja', 'tr', 'ru']), 'tr');
});

test('SUPPORTED lists the seven Flutter locales', () => {
  assert.deepEqual([...SUPPORTED].sort(), ['be', 'en', 'ka', 'pl', 'ru', 'tr', 'uk']);
});

test('setLocale notifies subscribers and unsubscribe stops it', () => {
  let calls = 0;
  const off = onLocaleChange(() => { calls += 1; });
  setLocale('ru');
  assert.equal(calls, 1);
  assert.equal(getLocale(), 'ru');
  off();
  setLocale('en');
  assert.equal(calls, 1);
  assert.equal(getLocale(), 'en');
});

test('t reflects the active locale', () => {
  setLocale('en');
  assert.equal(t.tabArchive, 'Archive');
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — "Cannot find module '../app/i18n/index.js'".

- [ ] **Step 3: Write the implementation**

Create `webapp/app/i18n/index.ts`. Locale imports are added one per translation task; for now the map holds only `en`, with the others aliased so the type stays honest and the build stays green.

```ts
/**
 * Locale registry and the active catalogue.
 *
 * `t` is an ESM live binding: reassigning it here updates every importer that
 * reads `t.key` at call time. Call sites must NEVER destructure it or capture
 * it at module scope — that snapshots one language.
 *
 * Nothing here touches navigator/document/localStorage at module scope, so the
 * module is importable under `node --test`. Browser access is confined to
 * initI18n().
 */
import { en, type Messages } from './en.js';
import { setPluralLocale } from './plural.js';

export const SUPPORTED = ['en', 'ru', 'tr', 'uk', 'ka', 'pl', 'be'] as const;
export type Locale = (typeof SUPPORTED)[number];

const STORAGE_KEY = 'nfar-lang';

// Later tasks replace each `en` alias with the real catalogue import.
const CATALOGUES: Record<Locale, Messages> = {
  en, ru: en, tr: en, uk: en, ka: en, pl: en, be: en,
};

let active: Locale = 'en';
export let t: Messages = en;

const listeners: Array<() => void> = [];

export function getLocale(): Locale {
  return active;
}

function isSupported(v: string): v is Locale {
  return (SUPPORTED as readonly string[]).includes(v);
}

/** First entry in `preferred` whose primary subtag is supported; else 'en'. */
export function pickLocale(preferred: readonly string[]): Locale {
  for (const tag of preferred) {
    const primary = tag.split('-')[0]?.toLowerCase() ?? '';
    if (isSupported(primary)) return primary;
  }
  return 'en';
}

export function setLocale(locale: Locale): void {
  active = locale;
  t = CATALOGUES[locale];
  setPluralLocale(locale);
  for (const fn of [...listeners]) fn();
}

export function onLocaleChange(fn: () => void): () => void {
  listeners.push(fn);
  return () => {
    const i = listeners.indexOf(fn);
    if (i >= 0) listeners.splice(i, 1);
  };
}

/** Browser-only. Applies the stored override if there is one, else the browser
 *  locale. Call once, before any panel initialises. */
export function initI18n(): void {
  const saved = localStorage.getItem(STORAGE_KEY);
  setLocale(saved !== null && isSupported(saved) ? saved : pickLocale(navigator.languages ?? [navigator.language]));
}

/** Browser-only. Persists an explicit user choice. */
export function storeLocale(locale: Locale): void {
  localStorage.setItem(STORAGE_KEY, locale);
  setLocale(locale);
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/i18n/index.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): locale registry, detection, and switching"
```

---

### Task 4: Static markup and the language selector

**Files:**
- Create: `webapp/app/i18n/dom.ts`
- Modify: `webapp/app/index.html`, `webapp/app/main.ts`, `webapp/app/ui/shell.ts`
- Test: `webapp/test/i18n.test.ts` (append)

**Interfaces:**
- Consumes: `t`, `onLocaleChange`, `initI18n`, `storeLocale`, `getLocale`, `SUPPORTED`, `type Locale` (Task 3).
- Produces: `applyStaticText(root?: ParentNode): void`, and the `LOCALE_NAMES: Record<Locale, string>` map used by the selector.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/i18n.test.ts`. This is the drift test — it reads the HTML as text, so it needs no DOM:

```ts
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LOCALE_NAMES } from '../app/i18n/dom.js';

test('every data-i18n attribute in index.html resolves to a real key', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app/index.html', import.meta.url)), 'utf8');
  const keys = [...html.matchAll(/data-i18n(?:-placeholder|-title)?="([^"]+)"/g)].map((m) => m[1]!);
  assert.ok(keys.length > 20, `expected the markup to be annotated, found ${keys.length}`);
  for (const key of keys) {
    assert.ok(key in en, `index.html references unknown message key "${key}"`);
    assert.equal(typeof en[key as keyof Messages], 'string', `"${key}" is a function; data-i18n needs a plain string`);
  }
});

test('LOCALE_NAMES covers every supported locale', () => {
  for (const l of SUPPORTED) assert.ok(LOCALE_NAMES[l], `no display name for ${l}`);
});
```

> Note on the path: compiled tests run from `dist/test/`, and `dist` sits beside `app/`, so `../../app/index.html` from `dist/test/i18n.test.js` resolves to `webapp/app/index.html`. Verify this in Step 2 — if the assertion fails with ENOENT, print `fileURLToPath(import.meta.url)` and correct the relative depth before continuing.

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — "Cannot find module '../app/i18n/dom.js'".

- [ ] **Step 3a: Write `app/i18n/dom.ts`**

```ts
/** Translates static markup annotated with data-i18n attributes. */
import { t } from './index.js';
import type { Locale } from './index.js';

/** Language names are always shown in their own language, so a user who lands
 *  in the wrong locale can still find theirs. */
export const LOCALE_NAMES: Record<Locale, string> = {
  en: 'English',
  ru: 'Русский',
  tr: 'Türkçe',
  uk: 'Українська',
  ka: 'ქართული',
  pl: 'Polski',
  be: 'Беларуская',
};

function lookup(key: string): string | null {
  const value = (t as unknown as Record<string, unknown>)[key];
  return typeof value === 'string' ? value : null;
}

export function applyStaticText(root: ParentNode = document): void {
  for (const el of Array.from(root.querySelectorAll<HTMLElement>('[data-i18n]'))) {
    const v = lookup(el.dataset['i18n'] ?? '');
    if (v !== null) el.textContent = v;
  }
  for (const el of Array.from(root.querySelectorAll<HTMLElement>('[data-i18n-placeholder]'))) {
    const v = lookup(el.dataset['i18nPlaceholder'] ?? '');
    if (v !== null) el.setAttribute('placeholder', v);
  }
  for (const el of Array.from(root.querySelectorAll<HTMLElement>('[data-i18n-title]'))) {
    const v = lookup(el.dataset['i18nTitle'] ?? '');
    if (v !== null) el.setAttribute('title', v);
  }
}
```

- [ ] **Step 3b: Annotate `app/index.html`**

Add the attributes below. Leave every other element untouched — in particular the `<h1>NFC Archiver</h1>`, `<title>`, the Mifare/NTAG `<option>` labels, and the `debug`/`info`/`warn`/`error` log-level options.

| Selector | Change |
|---|---|
| `#theme-toggle` | add `data-i18n-title="themeToggle"` |
| `#connect` | add `data-i18n="connect"` |
| `#conn` | add `data-i18n="statusDisconnected"` |
| `#inspect` | add `data-i18n="inspectCard"` |
| `#tabs button[data-tab="archive"]` … `="about"` | add `data-i18n="tabArchive"` / `tabRestore` / `tabFiles` / `tabLog` / `tabAbout` |
| the `<label>` reading `or text:` | add `data-i18n="orText"` |
| `#text` | add `data-i18n-placeholder="textPlaceholder"` |
| `#apass` | add `data-i18n-placeholder="optionalPlaceholder"` |
| `#target-tag option[value="auto"]` | add `data-i18n="targetAuto"` |
| `#archive` | add `data-i18n="archiveToCards"` |
| `#archive-status` | add `data-i18n="archiveIdle"` |
| `#scan` | add `data-i18n="scanCards"` |
| `#stop-scan` | add `data-i18n="stop"` |
| `#restore-status` | add `data-i18n="restoreIdle"` |
| `#files-empty` | add `data-i18n="filesEmpty"` |
| `#files-clear` | add `data-i18n="clearAll"` |
| `#log-clear` / `#log-copy` / `#log-download` | add `data-i18n="clear"` / `"copy"` / `"download"` |
| `#overwrite-message` | add `data-i18n="errOverwriteRequired"` |
| overwrite `button[value="once"]` / `="all"` / `#overwrite-skip` | add `data-i18n="overwrite"` / `"overwriteAll"` / `"skip"` |
| inspect dialog `<strong>Inspect card</strong>` | wrap unchanged, add `data-i18n="inspectCard"` |
| `#inspect-copy` / `#inspect-download` / `#inspect-close` | add `data-i18n="copy"` / `"download"` / `"close"` |
| the three inspect `<h4>` elements | add `data-i18n="inspectIdentity"` / `"inspectNfar"` / `"inspectRaw"` |

The `target tag`, `compress`, `password`, `save as`, `level`, `auto-scroll` and `mirror to console` labels wrap their inputs, so annotating the `<label>` would erase the input. Wrap each label's text in a `<span>` and annotate the span. Example — replace:

```html
<label><input type="checkbox" id="compress" checked /> compress</label>
```

with:

```html
<label><input type="checkbox" id="compress" checked /> <span data-i18n="compress">compress</span></label>
```

Apply the same `<span>` treatment to `targetTag`, `password`, `saveAs`, `logLevel`, `autoScroll`, `mirrorToConsole`.

Finally add the language selector to the header, immediately before `#theme-toggle`:

```html
<select id="lang" title="Language"></select>
```

and give it a style rule alongside `#theme-toggle` in the `<style>` block:

```css
#lang { background: transparent; border: 1px solid currentColor; color: inherit; border-radius: 8px; padding: 0.3rem; }
#lang option { color: initial; background: initial; }
```

- [ ] **Step 3c: Wire the selector in `app/ui/shell.ts`**

Add to the imports:

```ts
import { SUPPORTED, getLocale, storeLocale, onLocaleChange, type Locale } from '../i18n/index.js';
import { applyStaticText, LOCALE_NAMES } from '../i18n/dom.js';
```

Add this function and call it from `initShell()` after `initTheme()`:

```ts
function initLanguage(): void {
  const sel = $('lang') as HTMLSelectElement;
  for (const l of SUPPORTED) {
    const opt = document.createElement('option');
    opt.value = l;
    opt.textContent = LOCALE_NAMES[l];
    sel.appendChild(opt);
  }
  sel.value = getLocale();
  sel.addEventListener('change', () => { storeLocale(sel.value as Locale); });
  // Re-translate the markup on every change, and set <html lang> so screen
  // readers and hyphenation follow the UI.
  onLocaleChange(() => {
    document.documentElement.setAttribute('lang', getLocale());
    applyStaticText();
    sel.value = getLocale();
  });
  document.documentElement.setAttribute('lang', getLocale());
  applyStaticText();
}
```

- [ ] **Step 3d: Initialise i18n first in `app/main.ts`**

`initI18n()` must run before any panel builds text:

```ts
/** Entry point: pick a language, then initialize the shell, device bar, and panels. */
import { initI18n } from './i18n/index.js';
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';
import { initRestorePanel } from './ui/restore-panel.js';
import { initFilesPanel } from './ui/files-panel.js';
import { initLogPanel } from './ui/log-panel.js';
import { initAboutPanel } from './ui/about-panel.js';

initI18n();
initShell();
initDeviceBar();
initArchivePanel();
initRestorePanel();
initFilesPanel();
initLogPanel();
initAboutPanel();
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS, including the drift test finding more than 20 annotated keys.

- [ ] **Step 5: Verify in the browser**

```bash
cd webapp && npm run app
```

Open `localhost:8000` (on the Windows host if in WSL). Confirm: the language `<select>` lists all seven names in their own scripts, the page still reads correctly in English, and switching language changes nothing yet (all catalogues still alias `en`) without throwing. Check the console is clean.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/i18n/dom.ts webapp/app/index.html webapp/app/main.ts webapp/app/ui/shell.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): translate static markup and add the language selector"
```

---

### Task 5: Translate the error seam, device bar, and About panel

**Files:**
- Modify: `webapp/app/ui/errors.ts`, `webapp/app/ui/device.ts`, `webapp/app/ui/about-panel.ts`
- Test: `webapp/test/errors.test.ts` (verify it still passes unchanged)

**Interfaces:**
- Consumes: `t` (Task 3), `onLocaleChange` (Task 3).
- Produces: no new exports. `humanError(e)` keeps its signature `(e: unknown) => string`.

- [ ] **Step 1: Run the existing error tests to establish the baseline**

```bash
cd webapp && rm -rf dist && npm test -- --test-name-pattern='.*'
```

Note how many tests pass. `test/errors.test.ts` asserts the English strings; because the default locale is `en`, it must keep passing untouched after this task. That is the regression gate.

- [ ] **Step 2: Rewrite `app/ui/errors.ts`**

```ts
/** Maps a caught error to a plain-language, user-facing message. The single
 *  translation seam for everything src/ throws — src/ itself stays English. */
import { CardAuthError, CardReadError, WriteVerifyError, TagTimeoutError, UnsupportedTagError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';
import { DecryptionError } from '../../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../controller.js';
import { NdefFormatError } from '../../src/nfc/ndef.js';
import { t } from '../i18n/index.js';

export function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return t.errCardAuth;
  if (e instanceof CardReadError) return t.errCardRead;
  if (e instanceof WriteVerifyError) return t.errWriteVerify;
  if (e instanceof CardCapacityError) return t.errCardCapacity;
  if (e instanceof TagTimeoutError) return t.errTagTimeout;
  if (e instanceof NfarFormatError) return t.errNfarFormat;
  if (e instanceof OverwriteRequiredError) return t.errOverwriteRequired;
  if (e instanceof PasswordRequiredError) return t.errPasswordRequired;
  if (e instanceof DecryptionError) return t.errWrongPassword;
  if (e instanceof UnsupportedTagError) return t.errUnsupportedTag;
  if (e instanceof NdefFormatError) return t.errNdefFormat;
  if (e instanceof DOMException && e.name === 'AbortError') return t.cancelled;
  return e instanceof Error ? e.message : String(e);
}
```

- [ ] **Step 3: Update `app/ui/device.ts`**

Add `import { t } from '../i18n/index.js';` and replace the four literals — leaving every `log.*` call unchanged:

- line ~68 `$('conn').textContent = 'disconnected';` → `= t.statusDisconnected;`
- line ~69 `deviceStatus.textContent = 'Reader disconnected — click Connect to resume.';` → `= t.readerDisconnectedClickConnect;`
- line ~78 `$('conn').textContent = 'connected';` → `= t.statusConnected;`
- line ~82 `deviceStatus.textContent = 'Connected.';` → `= t.connectedDot;`

- [ ] **Step 4: Rewrite `app/ui/about-panel.ts`**

The module-level `SECTIONS` array must move inside the render function — a module-level constant would snapshot the language at import time. The panel also re-renders on language change.

```ts
/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION, BUILD_SHA } from '../version.js';
import { t } from '../i18n/index.js';
import { onLocaleChange } from '../i18n/index.js';

/** Built per render — reading `t` at module scope would freeze one language. */
function sections(): Array<{ h: string; body: string[] }> {
  return [
    { h: 'NFC Archiver', body: [t.aboutWebVersion(APP_VERSION, BUILD_SHA), t.aboutDescription] },
    { h: t.aboutSupportedHeading, body: [t.aboutSupportedBody, t.aboutWebNfcNote] },
    { h: t.aboutPrivacyHeading, body: [t.aboutPrivacyBody] },
    { h: t.aboutLicensesHeading, body: [t.aboutLicenseApp, t.aboutLicenseSdk] },
  ];
}

function render(): void {
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
  for (const s of sections()) {
    const h = document.createElement('h3');
    h.textContent = s.h;
    container.appendChild(h);
    for (const line of s.body) {
      const p = document.createElement('p');
      p.className = 'muted';
      p.textContent = line;
      container.appendChild(p);
    }
  }
}

export function initAboutPanel(): void {
  render();
  onLocaleChange(render);
}
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS with the same count as Step 1 — `test/errors.test.ts` unchanged and still green, proving the English output is byte-identical.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/ui/errors.ts webapp/app/ui/device.ts webapp/app/ui/about-panel.ts
git commit -m "feat(webapp): route errors, device bar, and About through the catalogue"
```

---

### Task 6: Translate the archive path

**Files:**
- Modify: `webapp/app/ui/archive-panel.ts`, `webapp/app/ui/archive-orchestrator.ts`
- Test: `webapp/test/archive-orchestrator.test.ts` (verify unchanged and still passing)

**Interfaces:**
- Consumes: `t` (Task 3). No signature changes — `ArchiveIO` and `ArchiveOrchestrator.run()` are untouched.
- Produces: nothing new.

- [ ] **Step 1: Run the archive tests to establish the baseline**

```bash
cd webapp && rm -rf dist && npm test
```

Record the pass count. `test/archive-orchestrator.test.ts` asserts English status strings; it must remain untouched and green.

- [ ] **Step 2: Update `app/ui/archive-orchestrator.ts`**

Add `import { t } from '../i18n/index.js';`, then replace exactly these, leaving every `this.io.log.*` call alone:

```ts
  private render(written: number, total: number, done: boolean): void {
    this.io.showProgress(
      done ? t.progressDone(written, total) : t.progressWriting(written, total),
      written, total,
    );
    this.io.setStatus(done ? t.archiveDone(written) : t.tapCardOf(written + 1, total));
  }
```

- line ~65 `'Reader disconnected — reconnect to resume.'` → `t.readerDisconnectedResume`
- line ~77 `` `Card holds ${res.rechunkedTo.payloadSize} B/chunk — writing ${res.rechunkedTo.total} card(s) instead.` `` → `t.rechunked(res.rechunkedTo.payloadSize, res.rechunkedTo.total)`
- line ~81 `'No card detected — tap a card (hold it a few mm off)…'` → `t.noCardTapHold`
- line ~82 `'Unsupported tag — tap a Mifare Classic 1K or NTAG.'` → `t.unsupportedTapOther`
- line ~85 `'Skipped. Tap a different card…'` → `t.skippedTapDifferent`
- line ~94 `` `${humanError(e2)} — re-tap to retry.` `` → `t.retryAfter(humanError(e2))`
- line ~100 `` `${humanError(e)} — re-tap to retry.` `` → `t.retryAfter(humanError(e))`

- [ ] **Step 3: Update `app/ui/archive-panel.ts`**

Add `import { t } from '../i18n/index.js';` and replace:

- line ~65 `` el.textContent = `≈ ${count} card(s)${isAuto ? …}`; `` → `el.textContent = t.cardEstimate(count, isAuto);`
- line ~80 `setStatus('Choose a file or type text, then Archive to cards.')` → `setStatus(t.archiveReady)`
- line ~88 `setStatus('Pick a file or type some text first.')` → `setStatus(t.archivePickFirst)`

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS with the Step 1 count.

If `archive-orchestrator.test.ts` now fails on the estimate or `card(s)` strings, that is the plural change landing correctly — English now says "1 card" / "3 cards" where it used to say "card(s)". Update the **assertions** in the test to the new, correct English. Do not reintroduce `card(s)`.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/archive-panel.ts webapp/app/ui/archive-orchestrator.ts webapp/test/archive-orchestrator.test.ts
git commit -m "feat(webapp): route the archive path through the catalogue"
```

---

### Task 7: Translate the restore, files, and inspect paths

**Files:**
- Modify: `webapp/app/ui/restore-panel.ts`, `webapp/app/ui/restore-orchestrator.ts`, `webapp/app/ui/restore-view.ts`, `webapp/app/ui/files-panel.ts`, `webapp/app/ui/files-view.ts`, `webapp/app/ui/inspect-orchestrator.ts`
- Test: `webapp/test/restore-orchestrator.test.ts`, `webapp/test/restore-view.test.ts`, `webapp/test/files-view.test.ts`, `webapp/test/inspect-orchestrator.test.ts`

**Interfaces:**
- Consumes: `t` (Task 3). `RestoreIO`, `InspectIO`, `renderArchiveList` and `renderFileList` keep their current signatures.
- Produces: nothing new.

- [ ] **Step 1: Run the tests to establish the baseline**

```bash
cd webapp && rm -rf dist && npm test
```

Record the pass count.

- [ ] **Step 2: Update `app/ui/restore-panel.ts`**

Add `import { t } from '../i18n/index.js';` and replace:

- line ~35 `setStatus('Scan a pile of cards to detect archives.')` → `setStatus(t.restoreReady)`
- line ~45 `setStatus('Scanning — tap cards on the reader…')` → `setStatus(t.scanning)`
- line ~52 `setStatus('Tap more cards, or Restore a complete one.')` → `setStatus(t.tapMoreCards)`
- line ~56 `setStatus('Unsupported tag — tap a Mifare Classic 1K or NTAG.')` → `setStatus(t.unsupportedTapOther)`
- line ~57 `` setStatus(`Skipped a card: ${humanError(e)}`) `` → `setStatus(t.skippedCard(humanError(e)))`

- [ ] **Step 3: Update `app/ui/restore-orchestrator.ts`**

Add `import { t } from '../i18n/index.js';` and replace:

- line ~66 the ternary argument to `promptPassword` → `this.io.promptPassword(e instanceof DecryptionError ? t.promptWrongPassword : t.promptArchiveEncrypted)`
- line ~67 `this.io.setStatus('Cancelled.')` → `this.io.setStatus(t.cancelled)`
- line ~71 `this.io.setStatus('Too many failed password attempts.')` → `this.io.setStatus(t.tooManyPasswordAttempts)`
- line ~75 `` this.io.setStatus(`Restored ${result.data.length} bytes → ${name}.`) `` → `this.io.setStatus(t.restoredBytes(result.data.length, name))`

- [ ] **Step 4: Update `app/ui/restore-view.ts`**

Add `import { t } from '../i18n/index.js';` and replace the `label` function and the button text:

```ts
function label(a: DetectedArchive): string {
  return t.archiveRow(a.shortId, a.isEncrypted, a.received, a.totalChunks, a.complete);
}
```

and line ~36 `btn.textContent = 'Restore';` → `btn.textContent = t.restore;`

- [ ] **Step 5: Update `app/ui/files-panel.ts`**

Add `import { t } from '../i18n/index.js';` and replace:

- line ~25 `` setStatus(`Downloaded ${humanSize(data.length)} → ${name}.`) `` → `setStatus(t.downloadedTo(humanSize(data.length), name))`
- line ~31 the prompt ternary → `prompt(e instanceof DecryptionError ? t.promptWrongPassword : t.promptFileEncrypted) ?? undefined`
- line ~32 `setStatus('Cancelled.')` → `setStatus(t.cancelled)`
- line ~39 `setStatus('Too many failed password attempts.')` → `setStatus(t.tooManyPasswordAttempts)`
- line ~54 `` `${info.count} file(s) · ${humanSize(info.totalBytes)} stored` `` → `t.filesInfo(info.count, humanSize(info.totalBytes))`
- line ~61 `confirm('Delete all stored files? This cannot be undone.')` → `confirm(t.confirmClearAll)`
- line ~65 `` setStatus(`Cleared ${n} file(s).`) `` → `setStatus(t.clearedFiles(n))`

- [ ] **Step 6: Update `app/ui/files-view.ts`**

Add `import { t } from '../i18n/index.js';`. Leave `humanSize()` alone — byte-size formatting is an explicit non-goal. Replace:

```ts
function label(f: FileListItem): string {
  const when = new Date(f.createdAt).toLocaleString();
  return t.fileRow(f.name, humanSize(f.size), when, f.isEncrypted, f.totalChunks);
}
```

and line ~41 `dl.textContent = 'Download';` → `dl.textContent = t.download;`, line ~44 `del.textContent = 'Delete';` → `del.textContent = t.deleteBtn;`

- [ ] **Step 7: Update `app/ui/inspect-orchestrator.ts`**

Add `import { t } from '../i18n/index.js';` and replace only the six status/progress strings. **Leave the `NfarSource.reason` strings alone** — they are consumed by `formatNfar()` in `src/`, which is out of scope and stays English with the rest of the dump body.

- line ~105 `io.setStatus('Hold the card still on the reader…')` → `io.setStatus(t.inspectHoldStill)`
- line ~127 `` io.setProgress(done === total ? `${done}/${total} read` : `reading… ${done}/${total}`) `` → `io.setProgress(done === total ? t.inspectRead(done, total) : t.inspectReading(done, total))`
- line ~147-149 the three-way status ternary → `result.aborted ? t.inspectStopped : result.cardLost ? t.inspectCardLost : t.inspectDone`

- [ ] **Step 8: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS. Where a test asserts a string that the plural change altered (`card(s)` → `card`/`cards` in `restore-view.test.ts` and `files-view.test.ts`), update the **assertion** to the new correct English. Do not reintroduce `card(s)`.

- [ ] **Step 9: Verify the whole app in the browser**

```bash
cd webapp && npm run app
```

Walk every tab. Confirm no `undefined` appears anywhere and the console is clean. The UI should still read exactly as before, in English.

- [ ] **Step 10: Commit**

```bash
git add webapp/app/ui/restore-panel.ts webapp/app/ui/restore-orchestrator.ts webapp/app/ui/restore-view.ts webapp/app/ui/files-panel.ts webapp/app/ui/files-view.ts webapp/app/ui/inspect-orchestrator.ts webapp/test/
git commit -m "feat(webapp): route restore, files, and inspect through the catalogue"
```

---

### Task 8: Slavic translations (ru, uk, be, pl)

**Files:**
- Create: `webapp/app/i18n/ru.ts`, `webapp/app/i18n/uk.ts`, `webapp/app/i18n/be.ts`, `webapp/app/i18n/pl.ts`
- Modify: `webapp/app/i18n/index.ts` (real imports replacing the `en` aliases)
- Test: `webapp/test/i18n.test.ts` (append the parity tests)

**Interfaces:**
- Consumes: `Messages` (Task 2), `pr` (Task 1).
- Produces: `export const ru: Messages` and likewise `uk`, `be`, `pl`.

**Plural categories** (`Intl.PluralRules` returns these; all four locales behave the same for integers):

| n | ru / uk / be / pl |
|---|---|
| 1, 21, 31 | `one` |
| 2–4, 22–24 | `few` |
| 0, 5–20, 25–30 | `many` |

`other` never fires for integers but is required by the type — set it equal to the `many` form.

**Seed from the Flutter ARB.** Before translating, read `lib/l10n/app_ru.arb`, `app_uk.arb`, `app_be.arb`, `app_pl.arb` and reuse the existing wording for shared concepts so the two apps agree. The concrete mappings:

| webapp key | ARB key to copy wording from |
|---|---|
| `tabArchive`, `archiveToCards` | `createArchive` / `startArchiving` |
| `tabRestore`, `restore` | `restoreArchive` |
| `password` | `password` |
| `cancelled` | `cancel` |
| `compress` | `enableCompression` |
| `download` | `done` context — check `app_*.arb` for the closest verb |
| `errPasswordRequired` | `pleaseEnterPassword` |
| `tabAbout`, `aboutDescription` | `aboutAppDescription` |
| `deleteBtn`, `clear`, `copy`, `close`, `stop` | no ARB equivalent — translate fresh |

- [ ] **Step 1: Write the failing parity test**

Append to `webapp/test/i18n.test.ts`:

```ts
import { ru } from '../app/i18n/ru.js';
import { uk } from '../app/i18n/uk.js';
import { be } from '../app/i18n/be.js';
import { pl } from '../app/i18n/pl.js';

const SLAVIC: Array<[string, Messages]> = [['ru', ru], ['uk', uk], ['be', be], ['pl', pl]];

test('Slavic catalogues match the English key set exactly', () => {
  const expected = Object.keys(en).sort();
  for (const [name, cat] of SLAVIC) {
    assert.deepEqual(Object.keys(cat).sort(), expected, `${name} key set differs`);
  }
});

test('Slavic catalogues match English entry shapes and arity', () => {
  for (const [name, cat] of SLAVIC) {
    for (const key of Object.keys(en) as Array<keyof Messages>) {
      const a = en[key], b = cat[key];
      assert.equal(typeof b, typeof a, `${name}.${String(key)} has the wrong type`);
      if (typeof a === 'function' && typeof b === 'function') {
        assert.equal(b.length, a.length, `${name}.${String(key)} has the wrong arity`);
      } else {
        assert.notEqual(b, '', `${name}.${String(key)} is empty`);
      }
    }
  }
});

test('Slavic plurals select the right form at the boundaries', () => {
  setPluralLocale('ru');
  const one = ru.clearedFiles(1), few = ru.clearedFiles(2), many = ru.clearedFiles(5);
  assert.notEqual(one, few);
  assert.notEqual(few, many);
  assert.equal(ru.clearedFiles(21), one.replace('1', '21'));
});
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — "Cannot find module '../app/i18n/ru.js'".

- [ ] **Step 3: Write the four catalogues**

Each file follows this exact shape. Translate **every** key from `en.ts` — `tsc` will not compile the file until all are present, which is the completeness gate.

```ts
/** Russian catalogue. Shared terms seeded from lib/l10n/app_ru.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

export const ru: Messages = {
  connect: 'Подключить Chameleon',
  inspectCard: 'Осмотреть карту',
  themeToggle: 'Светлая/тёмная тема',
  language: 'Язык',
  statusConnected: 'подключено',
  statusDisconnected: 'отключено',
  connectedDot: 'Подключено.',
  readerDisconnectedClickConnect: 'Считыватель отключён — нажмите «Подключить», чтобы продолжить.',
  tabArchive: 'Архивировать',
  tabRestore: 'Восстановить',
  tabFiles: 'Файлы',
  tabLog: 'Журнал',
  tabAbout: 'О программе',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, { one: 'карта', few: 'карты', many: 'карт', other: 'карт' })}${isAuto ? ' (оценка) — подстроится под карту' : ''}`,
  tapCardOf: (i, total) => `Приложите карту ${i} из ${total} к считывателю…`,
  archiveDone: (n) => `Готово — записано и проверено ${n} ${pr(n, { one: 'карта', few: 'карты', many: 'карт', other: 'карт' })}.`,
  // …every remaining key from en.ts…
};
```

Note that function parameters need no type annotations — they are inferred from `Messages`.

Repeat for `uk.ts` (`export const uk: Messages`), `be.ts` (`export const be: Messages`), `pl.ts` (`export const pl: Messages`). Polish plural forms use the same three categories: e.g. `{ one: 'karta', few: 'karty', many: 'kart', other: 'kart' }`.

- [ ] **Step 4: Wire them into the registry**

In `app/i18n/index.ts`, add the imports and replace the aliases:

```ts
import { ru } from './ru.js';
import { uk } from './uk.js';
import { be } from './be.js';
import { pl } from './pl.js';

const CATALOGUES: Record<Locale, Messages> = {
  en, ru, tr: en, uk, ka: en, pl, be,
};
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 6: Verify in the browser**

```bash
cd webapp && npm run app
```

Switch to Русский, Українська, Беларуская and Polski in turn. Check every tab for untranslated text, clipped buttons, and layout overflow — Slavic strings run noticeably longer than English. Confirm the Log tab entries are still English.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/i18n/ru.ts webapp/app/i18n/uk.ts webapp/app/i18n/be.ts webapp/app/i18n/pl.ts webapp/app/i18n/index.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): Russian, Ukrainian, Belarusian, and Polish translations"
```

---

### Task 9: Turkish and Georgian translations

**Files:**
- Create: `webapp/app/i18n/tr.ts`, `webapp/app/i18n/ka.ts`
- Modify: `webapp/app/i18n/index.ts`
- Test: `webapp/test/i18n.test.ts` (extend the parity tests to all six)

**Interfaces:**
- Consumes: `Messages` (Task 2), `pr` (Task 1).
- Produces: `export const tr: Messages`, `export const ka: Messages`.

**Plural categories:** both locales use `one` and `other` only. Turkish `one` applies to n = 1; Georgian `one` applies to n = 1. Everything else is `other`.

**Seed from** `lib/l10n/app_tr.arb` and `lib/l10n/app_ka.arb` using the same mapping table as Task 8.

- [ ] **Step 1: Extend the parity test**

In `webapp/test/i18n.test.ts`, add the imports and generalise the two parity tests from the Slavic four to all six locales:

```ts
import { tr } from '../app/i18n/tr.js';
import { ka } from '../app/i18n/ka.js';

const ALL_TRANSLATIONS: Array<[string, Messages]> = [
  ['ru', ru], ['uk', uk], ['be', be], ['pl', pl], ['tr', tr], ['ka', ka],
];

test('every translation matches the English key set exactly', () => {
  const expected = Object.keys(en).sort();
  for (const [name, cat] of ALL_TRANSLATIONS) {
    assert.deepEqual(Object.keys(cat).sort(), expected, `${name} key set differs`);
  }
});

test('every translation matches English entry shapes and arity', () => {
  for (const [name, cat] of ALL_TRANSLATIONS) {
    for (const key of Object.keys(en) as Array<keyof Messages>) {
      const a = en[key], b = cat[key];
      assert.equal(typeof b, typeof a, `${name}.${String(key)} has the wrong type`);
      if (typeof a === 'function' && typeof b === 'function') {
        assert.equal(b.length, a.length, `${name}.${String(key)} has the wrong arity`);
      } else {
        assert.notEqual(b, '', `${name}.${String(key)} is empty`);
      }
    }
  }
});

test('Turkish and Georgian use one/other only', () => {
  setPluralLocale('tr');
  assert.equal(tr.clearedFiles(2), tr.clearedFiles(5));
  setPluralLocale('ka');
  assert.equal(ka.clearedFiles(2), ka.clearedFiles(5));
});
```

Delete the now-superseded `SLAVIC` parity tests, keeping the `Slavic plurals` boundary test.

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: FAIL — "Cannot find module '../app/i18n/tr.js'".

- [ ] **Step 3: Write both catalogues**

Same shape as Task 8, `export const tr: Messages = { … }` and `export const ka: Messages = { … }`, translating every key. Plural entries take the two-form shape:

```ts
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, { one: 'kart', other: 'kart' })}${isAuto ? ' (tahmini) — karta göre uyarlanır' : ''}`,
```

- [ ] **Step 4: Wire them into the registry**

In `app/i18n/index.ts`:

```ts
import { tr } from './tr.js';
import { ka } from './ka.js';

const CATALOGUES: Record<Locale, Messages> = { en, ru, tr, uk, ka, pl, be };
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS.

- [ ] **Step 6: Verify in the browser**

```bash
cd webapp && npm run app
```

Switch to Türkçe and ქართული. Georgian has no uppercase and renders taller than Latin — check the header, tab strip, and dialog buttons for clipping.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/i18n/tr.ts webapp/app/i18n/ka.ts webapp/app/i18n/index.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): Turkish and Georgian translations"
```

---

### Task 10: Document and verify the production build

**Files:**
- Modify: `webapp/README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Verify the production build still passes its own checks**

```bash
cd webapp && rm -rf dist site && BUILD_SHA=$(git rev-parse HEAD) npm run build:site
```

Expected: the build prints `site/ built and verified — nfar-build:<sha>, bundle <N> B`. Compare `<N>` against the pre-localization size (~176 KB) and confirm the growth is in the single-digit-KB range as designed. If the build fails on the marker or SHA assertions, the localization did not cause it — re-run on `master` to confirm before investigating.

- [ ] **Step 2: Add a localization section to `webapp/README.md`**

Document, in the existing style: the seven supported locales; that `app/i18n/en.ts` is the schema and adding a key there breaks the other six until translated; that `data-i18n` attributes in `index.html` are validated by a test; that log entries and the card-inspection report body stay English by design; and that `t` must never be captured at module scope.

- [ ] **Step 3: Update the webapp section of `CLAUDE.md`**

Under `## Web App (webapp/)`, change the **Status** line — localization is no longer deferred; only Web NFC and the file manager remain. Add one bullet:

> - **Localization:** seven locales (en, ru, tr, uk, ka, pl, be) in `app/i18n/`, bundled as typed modules. `en.ts` is the schema — every other catalogue is `: Messages`, so `tsc` fails until a new key is translated everywhere. Static markup is annotated with `data-i18n` and validated by `test/i18n.test.ts`. Log entries and the card-inspection report deliberately stay English.

- [ ] **Step 4: Final full verification**

```bash
cd webapp && rm -rf dist && npm test
```

Expected: PASS — all pre-existing tests plus the new i18n suite.

- [ ] **Step 5: Commit**

```bash
git add webapp/README.md CLAUDE.md
git commit -m "docs(webapp): document the localization layer"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 module boundary, catalogue shape, no `as const` | 1, 2 |
| §2 static text, `data-i18n`, `<html lang>`, untranslated list | 4 |
| §3 dynamic strings, `humanError` seam, logs stay English | 5, 6, 7 |
| §4 plurals via `Intl.PluralRules`, `plural.ts` module | 1, 8, 9 |
| §5 detection, override, `localStorage`, re-render registry | 3, 4 |
| §6 all six tests | 1 (plural), 3 (detection), 4 (markup drift), 8–9 (parity, shape, boundaries) |
| §6 "no empty values" + allow-list | 2, 8, 9 — **narrowed, see below** |
| Non-goals | honored: `src/` untouched, no RTL, `humanSize()` left alone |

**Deviation from the spec, deliberate:** the spec's test 3 called for `app/i18n/same-as-english.ts`, an allow-list of keys permitted to equal their English source. The parity tests in Tasks 8–9 assert non-empty rather than not-equal-to-English. Reason: several keys are legitimately identical across locales (`encrypted` contains only an emoji plus a word, `plain`, and the Polish/Turkish forms of some technical terms), so the allow-list would need to be populated by inspection during translation anyway, and an allow-list that grows to cover a third of the catalogue asserts nothing. The compiler already guarantees presence; a human reading the diff catches an untranslated string better than a list does. **If you want the allow-list anyway, say so and it becomes Task 8 Step 3b** — it is a five-line test plus a data file.

**Placeholder scan:** none. Every code step contains the actual code; every string-replacement step names the file, the approximate line, the old text and the new expression. The two translation tasks give the file shape, the plural tables, the ARB seed mapping and a worked example rather than 600 pre-written strings — the translations themselves are the implementer's output, and `tsc` is the completeness gate.

**Type consistency:** `pr`/`PluralForms`/`setPluralLocale` (Task 1) are used identically in Tasks 2, 8, 9. `Messages` (Task 2) is the annotation in Tasks 3, 8, 9. `t`, `onLocaleChange`, `SUPPORTED`, `Locale`, `getLocale`, `storeLocale`, `initI18n` (Task 3) are consumed with matching names in Tasks 4–7. `applyStaticText` and `LOCALE_NAMES` (Task 4) match their test usage. No `ArchiveIO`, `RestoreIO`, `InspectIO`, `renderArchiveList` or `renderFileList` signature changes anywhere.
