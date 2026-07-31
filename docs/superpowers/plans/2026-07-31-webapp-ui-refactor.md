# Webapp UI Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reskin the web app into an Android-shaped settings-list UI — borderless cards on a tonally lower page, tinted icon tiles, uppercase section labels, a segmented tab control — without changing a single behaviour.

**Architecture:** All presentation. The CSS stays inline in `app/index.html` (see Global Constraint 8), reorganised into labelled blocks. Markup is restructured panel by panel around a small closed set of component classes. Two view builders (`restore-view.ts`, `files-view.ts`) gain wrapper elements and their tests are updated to match. Ten new i18n keys land in all seven catalogues.

**Tech Stack:** TypeScript, esbuild, plain DOM, `node --test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-31-webapp-ui-refactor-design.md`

## Global Constraints

1. **Every element ID in `app/index.html` survives verbatim.** Eight modules resolve elements via `getElementById`; a renamed ID returns null, fails silently at runtime, and no test catches it.
2. `#tabs` keeps its ID and remains the ancestor of the tab buttons. `shell.ts` queries `#tabs button[data-tab="…"]`. Each button keeps `role="tab"`, its `data-tab` value, and `aria-selected`.
3. The five `data-tab` values are exactly `archive`, `restore`, `files`, `log`, `about`, matching `panel-archive` … `panel-about`.
4. `#conn` must carry **no** `data-i18n` attribute — asserted by `test/i18n.test.ts`.
5. Every `data-i18n`, `data-i18n-placeholder`, `data-i18n-title` attribute must resolve to a plain-string key in `app/i18n/en.ts`.
6. Dark mode works through **both** `@media (prefers-color-scheme: dark)` and `:root[data-theme="dark"]`, and light through `:root[data-theme="light"]`. The `data-theme` override must win.
7. No runtime dependency added. Nothing new imported into `src/`.
8. **CSS stays inline in `index.html`.** Extraction would require changing `scripts/build-site.ts` and the deploy's asset handling, both outside the approved spec scope.
9. Font stays `system-ui, sans-serif`. **No webfont** — Inter lacks Georgian coverage and `system-ui` is Roboto on Android.
10. Native form controls are kept and wrapped, never replaced by `div`s. `archive-panel.ts` must keep reading `$('compress').checked` unchanged.
11. Run `source ~/.nvm/nvm.sh && nvm use --lts` before any npm command (default shell Node is 14). Use `rm -rf dist && npm test` — the `tsc && node --test` chain does not clean stale compiled tests.
12. Baseline is **289 passing tests**. No task may reduce that count except by the deliberate test edits in Tasks 6 and 7, which replace assertions rather than remove them.

---

### Task 1: Design tokens and base layer

**Files:**
- Modify: `webapp/app/index.html` — the `:root` blocks and base element rules inside `<style>` (currently lines 8–33)

**Interfaces:**
- Consumes: nothing
- Produces: the CSS custom properties every later task uses — `--bg`, `--surface`, `--primary`, `--on-primary`, `--primary-light`, `--on-primary-light`, `--primary-icon-bg`, `--text`, `--text-secondary`, `--border`, `--error`, `--error-bg`, `--on-error-bg`, `--success`, `--success-bg`, `--warning`, `--radius`, `--radius-sm`, `--shadow`, `--shadow-md`

- [ ] **Step 1: Replace the token blocks**

Replace everything from `:root {` through the closing brace of `:root[data-theme="dark"] { … }` with the following. Note the token set is declared once in a named block and repeated for each of the three selectors, exactly as the current file does — `data-theme` must override the media query, so it comes last.

```css
/* ---------- tokens: light ---------- */
:root {
  --bg: #eef1f7;
  --surface: #ffffff;
  --primary: #0061a4;
  --on-primary: #ffffff;
  --primary-light: #d1e4ff;
  --on-primary-light: #001d36;
  --primary-icon-bg: #c5dcfa;
  --text: #1a1c1e;
  --text-secondary: #5b5f67;
  --border: #dfe2eb;
  --error: #ba1a1a;
  --error-bg: #ffdad6;
  --on-error-bg: #410002;
  --success: #2e7d52;
  --success-bg: #e6f4ed;
  --warning: #b76e00;
  --radius: 18px;
  --radius-sm: 12px;
  --shadow: 0 2px 14px rgba(16, 42, 71, 0.07);
  --shadow-md: 0 4px 22px rgba(16, 42, 71, 0.13);
}
/* ---------- tokens: dark ----------
   In dark mode a shadow separates almost nothing, so --surface sits tonally
   ABOVE --bg and carries the separation itself (the Material 3 elevation-tint
   approach). The shadow tokens stay defined so one rule set serves both. */
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111417; --surface: #1c1f22;
    --primary: #9ecaff; --on-primary: #003258;
    --primary-light: #00497d; --on-primary-light: #d1e4ff;
    --primary-icon-bg: #0d3c66;
    --text: #e3e2e6; --text-secondary: #a9adb5; --border: #2c3034;
    --error: #ffb4ab; --error-bg: #93000a; --on-error-bg: #ffdad6;
    --success: #7fd8a4; --success-bg: #10331f; --warning: #f0b357;
    --shadow: 0 2px 14px rgba(0, 0, 0, 0.35);
    --shadow-md: 0 4px 22px rgba(0, 0, 0, 0.5);
  }
}
:root[data-theme="light"] {
  --bg: #eef1f7; --surface: #ffffff;
  --primary: #0061a4; --on-primary: #ffffff;
  --primary-light: #d1e4ff; --on-primary-light: #001d36;
  --primary-icon-bg: #c5dcfa;
  --text: #1a1c1e; --text-secondary: #5b5f67; --border: #dfe2eb;
  --error: #ba1a1a; --error-bg: #ffdad6; --on-error-bg: #410002;
  --success: #2e7d52; --success-bg: #e6f4ed; --warning: #b76e00;
  --shadow: 0 2px 14px rgba(16, 42, 71, 0.07);
  --shadow-md: 0 4px 22px rgba(16, 42, 71, 0.13);
}
:root[data-theme="dark"] {
  --bg: #111417; --surface: #1c1f22;
  --primary: #9ecaff; --on-primary: #003258;
  --primary-light: #00497d; --on-primary-light: #d1e4ff;
  --primary-icon-bg: #0d3c66;
  --text: #e3e2e6; --text-secondary: #a9adb5; --border: #2c3034;
  --error: #ffb4ab; --error-bg: #93000a; --on-error-bg: #ffdad6;
  --success: #7fd8a4; --success-bg: #10331f; --warning: #f0b357;
  --shadow: 0 2px 14px rgba(0, 0, 0, 0.35);
  --shadow-md: 0 4px 22px rgba(0, 0, 0, 0.5);
}
```

- [ ] **Step 2: Replace the base element rules**

Replace the `* { box-sizing }`, `body`, `main`, `button`, and input rules with:

```css
/* ---------- base ---------- */
* { box-sizing: border-box; }
body {
  margin: 0;
  font: 14px/1.5 system-ui, sans-serif;
  background: var(--bg);
  color: var(--text);
  -webkit-font-smoothing: antialiased;
}
main { max-width: 36rem; margin: 0 auto; padding: 0 1rem 3rem; }
button { font: inherit; }
h1, h2, h3, h4 { margin: 0; }
.muted { color: var(--text-secondary); }
input[type="text"], input[type="password"], textarea, select {
  background: var(--surface);
  color: var(--text);
  border: 1.5px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 0.45rem 0.6rem;
  font: inherit;
  outline: none;
  transition: border-color 0.15s;
}
input[type="text"]:focus, input[type="password"]:focus,
textarea:focus, select:focus { border-color: var(--primary); }
textarea { width: 100%; resize: vertical; }
```

Leave every other existing rule in place for now; later tasks replace them.

- [ ] **Step 3: Verify the suite and the build**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing, `site/ built and verified`.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/index.html
git commit -m "style(webapp): Material 3 tokens with a page/surface tonal split"
```

---

### Task 2: Component vocabulary and icon sprite

**Files:**
- Modify: `webapp/app/index.html` — append component rules to `<style>`; add the sprite as the first child of `<body>`

**Interfaces:**
- Consumes: every token from Task 1
- Produces: classes `.section-label`, `.card`, `.row`, `.row-col`, `.icon-tile`, `.ico`, `.row-text`, `.row-name`, `.row-sub`, `.row-control`, `.switch`, `.seg`, `.seg-btn`, `.status-pill`, `.status-dot`, `.btn-primary`, `.btn-tonal`, `.btn-text`, `.status`; and sprite symbol ids `#i-file`, `#i-pencil`, `#i-card`, `#i-archive`, `#i-lock`, `#i-save`, `#i-folder`, `#i-download`

- [ ] **Step 1: Append the component rules**

```css
/* ---------- components ---------- */
.section-label {
  display: block;
  font-size: 12px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.09em; color: var(--text-secondary);
  padding: 0 4px 6px; margin-top: 1.25rem;
}
.card {
  background: var(--surface);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  overflow: hidden;
}
/* Rows own their padding; .card has none. */
.row {
  display: flex; align-items: center; gap: 14px;
  padding: 15px 18px;
  border-bottom: 1px solid var(--border);
}
.row:last-child { border-bottom: none; }
/* Deliberate exception for full-width controls (the textarea): label above,
   control stretched beneath, instead of the fixed-height row shape. */
.row-col { flex-direction: column; align-items: stretch; gap: 8px; }
.icon-tile {
  width: 38px; height: 38px; flex-shrink: 0;
  background: var(--primary-icon-bg);
  border-radius: 11px;
  display: flex; align-items: center; justify-content: center;
}
.ico {
  width: 18px; height: 18px;
  stroke: var(--primary); fill: none;
  stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round;
}
.row-text { flex: 1; min-width: 0; }
.row-name { font-size: 14px; font-weight: 500; color: var(--text); }
.row-sub { font-size: 12px; color: var(--text-secondary); margin-top: 1px; }
.row-control { flex-shrink: 0; display: flex; align-items: center; gap: 8px; }
.row-control input[type="text"], .row-control input[type="password"] { width: 9rem; }

/* Switch: wraps a real checkbox so focus, form semantics and screen-reader
   behaviour come for free. */
.switch { position: relative; display: inline-block; width: 44px; height: 24px; }
.switch input { position: absolute; opacity: 0; width: 0; height: 0; }
.switch-track {
  position: absolute; inset: 0; cursor: pointer;
  background: var(--border); border-radius: 24px; transition: background 0.2s;
}
.switch-track::before {
  content: ""; position: absolute;
  height: 18px; width: 18px; left: 3px; bottom: 3px;
  background: #fff; border-radius: 50%; transition: transform 0.2s;
}
.switch input:checked + .switch-track { background: var(--primary); }
.switch input:checked + .switch-track::before { transform: translateX(20px); }
.switch input:focus-visible + .switch-track { outline: 2px solid var(--primary); outline-offset: 2px; }

/* Segmented control — also the tab strip. Scrolls rather than overflowing:
   five labels in RU/KA do not fit a 360px viewport. */
.seg {
  display: flex; gap: 2px;
  background: var(--bg); border-radius: 10px; padding: 3px;
  overflow-x: auto; scrollbar-width: none; -webkit-overflow-scrolling: touch;
}
.seg::-webkit-scrollbar { display: none; }
.seg-btn {
  flex: 1 0 auto;
  padding: 7px 14px; border: none; background: transparent;
  border-radius: 8px; white-space: nowrap;
  font-size: 12px; font-weight: 600; color: var(--text-secondary);
  cursor: pointer; transition: background 0.15s, color 0.15s;
}
.seg-btn[aria-selected="true"] {
  background: var(--surface); color: var(--primary);
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.08);
}

.status-pill {
  display: flex; align-items: center; gap: 12px;
  background: var(--primary-light); color: var(--on-primary-light);
  border-radius: 50px; padding: 11px 18px;
  font-size: 13px; font-weight: 500;
}
.status-dot {
  width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0;
  background: var(--text-secondary);
}
.status-pill[data-connected="true"] .status-dot { background: var(--success); }

.btn-primary {
  display: block; width: 100%;
  padding: 17px; border: none; border-radius: var(--radius);
  background: var(--primary); color: var(--on-primary);
  font-size: 16px; font-weight: 600; cursor: pointer;
  box-shadow: var(--shadow-md);
  transition: opacity 0.15s, transform 0.1s;
}
.btn-primary:hover:not(:disabled) { opacity: 0.9; transform: translateY(-1px); }
.btn-primary:disabled { opacity: 0.45; cursor: default; box-shadow: none; transform: none; }
.btn-tonal {
  padding: 8px 16px; border: none; border-radius: var(--radius-sm);
  background: var(--primary-light); color: var(--on-primary-light);
  font-size: 13px; font-weight: 600; cursor: pointer; transition: opacity 0.15s;
}
.btn-tonal:hover:not(:disabled) { opacity: 0.85; }
.btn-tonal:disabled { opacity: 0.45; cursor: default; }
.btn-text {
  padding: 6px 10px; border: none; background: none;
  border-radius: 8px; color: var(--text-secondary);
  font-size: 13px; font-weight: 600; cursor: pointer; transition: color 0.15s;
}
.btn-text:hover:not(:disabled) { color: var(--text); }
.btn-text:disabled { opacity: 0.45; cursor: default; }

.status {
  padding: 12px 16px; margin-top: 0.75rem;
  background: var(--surface); border-radius: var(--radius-sm);
  box-shadow: var(--shadow);
  font-size: 13px; color: var(--text-secondary);
  min-height: 1.4rem; white-space: pre-wrap;
}

/* Kept as a native <progress>: archive-panel.ts drives indeterminate state by
   removing the value attribute, which a div-based bar cannot express. */
progress { width: 100%; height: 6px; border: none; background: var(--border); border-radius: 3px; }
progress::-webkit-progress-bar { background: var(--border); border-radius: 3px; }
progress::-webkit-progress-value { background: var(--primary); border-radius: 3px; }
progress::-moz-progress-bar { background: var(--primary); border-radius: 3px; }
.progress-label { display: block; font-size: 12px; color: var(--text-secondary); margin-top: 6px; }
.cardcount { font-size: 13px; color: var(--text-secondary); text-align: right; padding: 12px 18px 0; }
.sprite { display: none; }
```

- [ ] **Step 2: Add the icon sprite as the first child of `<body>`**

```html
<svg class="sprite" aria-hidden="true">
  <symbol id="i-file" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></symbol>
  <symbol id="i-pencil" viewBox="0 0 24 24"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/></symbol>
  <symbol id="i-card" viewBox="0 0 24 24"><rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/></symbol>
  <symbol id="i-archive" viewBox="0 0 24 24"><path d="M21 8v13H3V8"/><rect x="1" y="3" width="22" height="5" rx="1"/><path d="M10 12h4"/></symbol>
  <symbol id="i-lock" viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></symbol>
  <symbol id="i-save" viewBox="0 0 24 24"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/></symbol>
  <symbol id="i-folder" viewBox="0 0 24 24"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></symbol>
  <symbol id="i-download" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/></symbol>
</svg>
```

An icon is used as: `<span class="icon-tile"><svg class="ico"><use href="#i-file"/></svg></span>`

- [ ] **Step 3: Verify**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing, build verified.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/index.html
git commit -m "style(webapp): component vocabulary and inline icon sprite"
```

---

### Task 3: New i18n keys across seven locales

**Files:**
- Modify: `webapp/app/i18n/en.ts` (the schema — add here first)
- Modify: `webapp/app/i18n/ru.ts`, `tr.ts`, `uk.ts`, `ka.ts`, `pl.ts`, `be.ts`

**Interfaces:**
- Consumes: nothing
- Produces: ten plain-string keys — `sectionSource`, `sectionSettings`, `sectionArchives`, `sectionRestoredFiles`, `sectionLogOptions`, `subChooseFile`, `subTypeText`, `subTargetTag`, `subCompress`, `subPassword`

`en.ts` declares `Messages`; every other catalogue is typed `: Messages`, so `tsc` fails until all seven have all ten. That is the enforcement — there is no separate test to write.

- [ ] **Step 1: Add the keys to `en.ts`**

Insert after the existing `readerBusyElsewhere` entry:

```ts
  sectionSource: 'Source',
  sectionSettings: 'Settings',
  sectionArchives: 'Detected archives',
  sectionRestoredFiles: 'Restored files',
  sectionLogOptions: 'Log options',
  subChooseFile: 'Any file, split across cards',
  subTypeText: 'Saved as text_note.txt',
  subTargetTag: 'Card type and capacity',
  subCompress: 'GZIP before writing',
  subPassword: 'AES-256-GCM, optional',
```

- [ ] **Step 2: Run tsc to watch it fail for the other six**

```bash
cd webapp && npx tsc
```
Expected: FAIL — six errors, one per catalogue, each naming the missing properties.

- [ ] **Step 3: Add the translations**

Insert the matching block after `readerBusyElsewhere` in each file.

`ru.ts`:
```ts
  sectionSource: 'Источник',
  sectionSettings: 'Настройки',
  sectionArchives: 'Найденные архивы',
  sectionRestoredFiles: 'Восстановленные файлы',
  sectionLogOptions: 'Параметры журнала',
  subChooseFile: 'Любой файл, разбитый по картам',
  subTypeText: 'Сохраняется как text_note.txt',
  subTargetTag: 'Тип карты и ёмкость',
  subCompress: 'GZIP перед записью',
  subPassword: 'AES-256-GCM, необязательно',
```

`uk.ts`:
```ts
  sectionSource: 'Джерело',
  sectionSettings: 'Налаштування',
  sectionArchives: 'Знайдені архіви',
  sectionRestoredFiles: 'Відновлені файли',
  sectionLogOptions: 'Параметри журналу',
  subChooseFile: 'Будь-який файл, розділений по картках',
  subTypeText: 'Зберігається як text_note.txt',
  subTargetTag: 'Тип картки та ємність',
  subCompress: 'GZIP перед записом',
  subPassword: 'AES-256-GCM, необов’язково',
```

`be.ts`:
```ts
  sectionSource: 'Крыніца',
  sectionSettings: 'Налады',
  sectionArchives: 'Знойдзеныя архівы',
  sectionRestoredFiles: 'Адноўленыя файлы',
  sectionLogOptions: 'Параметры журнала',
  subChooseFile: 'Любы файл, падзелены па картах',
  subTypeText: 'Захоўваецца як text_note.txt',
  subTargetTag: 'Тып карты і ёмістасць',
  subCompress: 'GZIP перад запісам',
  subPassword: 'AES-256-GCM, неабавязкова',
```

`pl.ts`:
```ts
  sectionSource: 'Źródło',
  sectionSettings: 'Ustawienia',
  sectionArchives: 'Wykryte archiwa',
  sectionRestoredFiles: 'Odtworzone pliki',
  sectionLogOptions: 'Opcje dziennika',
  subChooseFile: 'Dowolny plik, podzielony na karty',
  subTypeText: 'Zapisywane jako text_note.txt',
  subTargetTag: 'Typ karty i pojemność',
  subCompress: 'GZIP przed zapisem',
  subPassword: 'AES-256-GCM, opcjonalnie',
```

`tr.ts`:
```ts
  sectionSource: 'Kaynak',
  sectionSettings: 'Ayarlar',
  sectionArchives: 'Bulunan arşivler',
  sectionRestoredFiles: 'Geri yüklenen dosyalar',
  sectionLogOptions: 'Günlük seçenekleri',
  subChooseFile: 'Kartlara bölünecek herhangi bir dosya',
  subTypeText: 'text_note.txt olarak kaydedilir',
  subTargetTag: 'Kart türü ve kapasitesi',
  subCompress: 'Yazmadan önce GZIP',
  subPassword: 'AES-256-GCM, isteğe bağlı',
```

`ka.ts`:
```ts
  sectionSource: 'წყარო',
  sectionSettings: 'პარამეტრები',
  sectionArchives: 'ნაპოვნი არქივები',
  sectionRestoredFiles: 'აღდგენილი ფაილები',
  sectionLogOptions: 'ჟურნალის პარამეტრები',
  subChooseFile: 'ნებისმიერი ფაილი, დაყოფილი ბარათებზე',
  subTypeText: 'ინახება როგორც text_note.txt',
  subTargetTag: 'ბარათის ტიპი და ტევადობა',
  subCompress: 'GZIP ჩაწერამდე',
  subPassword: 'AES-256-GCM, არასავალდებულო',
```

- [ ] **Step 4: Verify**

```bash
cd webapp && rm -rf dist && npm test
```
Expected: PASS, 289 tests. `tsc` clean proves all seven catalogues are complete.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/i18n
git commit -m "i18n(webapp): section and sub-label strings for the settings-row UI"
```

---

### Task 4: Header, device bar and tab strip

**Files:**
- Modify: `webapp/app/index.html` — `<header>`, `#device-bar`, `#tabs` markup; replace their old CSS rules
- Modify: `webapp/app/ui/shell.ts` — scroll the selected tab into view
- Modify: `webapp/app/ui/device.ts` — set `data-connected` on the status pill

**Interfaces:**
- Consumes: Task 1 tokens, Task 2 components
- Produces: `#device-pill` (new id, the `.status-pill` wrapper) — `device.ts` sets `data-connected` on it

- [ ] **Step 1: Replace the header and device-bar CSS**

Delete the old `header`, `header h1`, `header svg`, `#theme-toggle`, `#lang`, `#device-bar`, `#device-bar button`, `#device-status`, `#tabs`, `#tabs button`, `#tabs button[aria-selected="true"]` rules. Add:

```css
/* ---------- shell ---------- */
header {
  display: flex; align-items: center; gap: 0.6rem;
  max-width: 36rem; margin: 0 auto; padding: 22px 1rem 10px;
}
header h1 { flex: 1; font-size: 17px; font-weight: 600; letter-spacing: -0.3px; }
header .brand { width: 26px; height: 26px; fill: var(--primary); flex-shrink: 0; }
#lang, #theme-toggle {
  height: 30px; border-radius: 15px;
  border: 1.5px solid var(--border); background: var(--surface);
  color: var(--text-secondary); cursor: pointer; padding: 0 0.6rem;
  font-size: 13px; transition: background 0.15s, color 0.15s;
}
#lang:hover, #theme-toggle:hover { background: var(--primary-light); color: var(--primary); }
#device-bar { max-width: 36rem; margin: 0 auto; padding: 0 1rem; }
#device-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-top: 0.6rem; }
#device-status {
  margin: 0.6rem 0 0; white-space: pre-wrap;
  font: 13px/1.4 ui-monospace, monospace; color: var(--text-secondary);
}
section[role="tabpanel"] { padding-top: 0.25rem; }
section[hidden] { display: none; }
```

- [ ] **Step 2: Replace the header, device bar and tab markup**

`#conn` keeps no `data-i18n` (Global Constraint 4). `#tabs` takes `.seg` directly and each button takes `.seg-btn` (Global Constraint 2).

```html
    <header>
      <svg class="brand" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zm-1 14H5V6h14v12zM7.5 9.5A1.5 1.5 0 0 1 9 8h6a1.5 1.5 0 0 1 1.5 1.5v5A1.5 1.5 0 0 1 15 16H9a1.5 1.5 0 0 1-1.5-1.5v-5zM9 9.5v5h6v-5H9z"/></svg>
      <h1>NFC Archiver</h1>
      <select id="lang" data-i18n-title="language" title="Language"></select>
      <button id="theme-toggle" data-i18n-title="themeToggle" title="Toggle light/dark">◑</button>
    </header>

    <div id="device-bar">
      <div id="device-pill" class="status-pill" data-connected="false">
        <span class="status-dot"></span>
        <!-- No data-i18n: this span mirrors live connection state, so device.ts
             owns it and re-renders it on locale change. applyStaticText() would
             overwrite "connected" with the disconnected text. -->
        <span id="conn">disconnected</span>
      </div>
      <div id="device-actions">
        <button id="connect" class="btn-tonal" data-i18n="connect">Connect Chameleon</button>
        <button id="use-web-nfc" class="btn-tonal" hidden data-i18n="usePhoneNfc">Use phone NFC</button>
        <button id="inspect" class="btn-tonal" disabled data-i18n="inspectCard">Inspect card</button>
        <button id="disconnect" class="btn-tonal" disabled data-i18n="disconnect">Disconnect</button>
      </div>
      <pre id="device-status"></pre>
    </div>

    <main>
      <div id="tabs" class="seg" role="tablist">
        <button class="seg-btn" role="tab" data-tab="archive" aria-selected="true" data-i18n="tabArchive">Archive</button>
        <button class="seg-btn" role="tab" data-tab="restore" aria-selected="false" data-i18n="tabRestore">Restore</button>
        <button class="seg-btn" role="tab" data-tab="files" aria-selected="false" data-i18n="tabFiles">Files</button>
        <button class="seg-btn" role="tab" data-tab="log" aria-selected="false" data-i18n="tabLog">Log</button>
        <button class="seg-btn" role="tab" data-tab="about" aria-selected="false" data-i18n="tabAbout">About</button>
      </div>
```

- [ ] **Step 3: Scroll the selected tab into view**

In `shell.ts`, inside `activateTab`'s loop, after `btn.setAttribute('aria-selected', String(selected));`:

```ts
    // The strip scrolls horizontally (five labels do not fit a 360px viewport
    // in RU or KA), so a selection off-screen must be brought into view.
    if (selected) btn.scrollIntoView({ block: 'nearest', inline: 'nearest' });
```

- [ ] **Step 4: Reflect connection state on the pill**

In `device.ts`, `renderConn()` currently sets only `#conn`'s text. Add the pill attribute so the dot colours:

```ts
function renderConn(): void {
  $('conn').textContent = connected ? t.statusConnected : t.statusDisconnected;
  $('device-pill').setAttribute('data-connected', String(connected));
}
```

- [ ] **Step 5: Verify**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing (the i18n test re-parses the new markup), build verified.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/shell.ts webapp/app/ui/device.ts
git commit -m "style(webapp): status-pill device bar and segmented tab strip"
```

---

### Task 5: Archive panel

**Files:**
- Modify: `webapp/app/index.html` — `#panel-archive` markup

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: nothing new. **Every id is unchanged**: `file`, `text`, `target-tag`, `compress`, `apass`, `cardcount`, `archive`, `archive-progress-row`, `archive-bar`, `archive-progress-label`, `archive-status`

- [ ] **Step 1: Replace the panel markup**

```html
      <section id="panel-archive" role="tabpanel">
        <span class="section-label" data-i18n="sectionSource">Source</span>
        <div class="card">
          <div class="row">
            <span class="icon-tile"><svg class="ico"><use href="#i-file"/></svg></span>
            <div class="row-text">
              <div class="row-name" data-i18n="tabArchive">Archive</div>
              <div class="row-sub" data-i18n="subChooseFile">Any file, split across cards</div>
            </div>
            <div class="row-control"><input type="file" id="file" /></div>
          </div>
          <div class="row row-col">
            <div style="display:flex;align-items:center;gap:14px">
              <span class="icon-tile"><svg class="ico"><use href="#i-pencil"/></svg></span>
              <div class="row-text">
                <div class="row-name" data-i18n="orText">or text:</div>
                <div class="row-sub" data-i18n="subTypeText">Saved as text_note.txt</div>
              </div>
            </div>
            <textarea id="text" rows="3" data-i18n-placeholder="textPlaceholder" placeholder="Type text to archive as text_note.txt"></textarea>
          </div>
        </div>

        <span class="section-label" data-i18n="sectionSettings">Settings</span>
        <div class="card">
          <div class="row">
            <span class="icon-tile"><svg class="ico"><use href="#i-card"/></svg></span>
            <div class="row-text">
              <div class="row-name" data-i18n="targetTag">target tag</div>
              <div class="row-sub" data-i18n="subTargetTag">Card type and capacity</div>
            </div>
            <div class="row-control">
              <select id="target-tag">
                <option value="auto" selected data-i18n="targetAuto">Auto-detect (adapts to the card)</option>
                <option value="720">Mifare Classic 1K — 752 B</option>
                <option value="NTAG213">NTAG213 — 144 B</option>
                <option value="NTAG215">NTAG215 — 504 B</option>
                <option value="NTAG216">NTAG216 — 888 B</option>
              </select>
            </div>
          </div>
          <div class="row">
            <span class="icon-tile"><svg class="ico"><use href="#i-archive"/></svg></span>
            <div class="row-text">
              <div class="row-name" data-i18n="compress">compress</div>
              <div class="row-sub" data-i18n="subCompress">GZIP before writing</div>
            </div>
            <div class="row-control">
              <label class="switch"><input type="checkbox" id="compress" checked /><span class="switch-track"></span></label>
            </div>
          </div>
          <div class="row">
            <span class="icon-tile"><svg class="ico"><use href="#i-lock"/></svg></span>
            <div class="row-text">
              <div class="row-name" data-i18n="password">password</div>
              <div class="row-sub" data-i18n="subPassword">AES-256-GCM, optional</div>
            </div>
            <div class="row-control">
              <input type="password" id="apass" data-i18n-placeholder="optionalPlaceholder" placeholder="(optional)" />
            </div>
          </div>
          <div id="cardcount" class="cardcount"></div>
        </div>

        <div style="margin-top:1.25rem">
          <button id="archive" class="btn-primary" disabled data-i18n="archiveToCards">Archive to cards</button>
        </div>

        <div class="card" id="archive-progress-row" hidden style="margin-top:0.75rem;padding:16px 18px">
          <progress id="archive-bar"></progress>
          <span id="archive-progress-label" class="progress-label"></span>
        </div>
        <div class="status" id="archive-status" data-i18n="archiveIdle">Connect a Chameleon, then choose a file or type text.</div>
      </section>
```

Note the file row reuses `tabArchive` as its name — no new key is spent on a label the section already implies.

- [ ] **Step 2: Verify**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing. The i18n test proves every new `data-i18n` here resolves.

- [ ] **Step 3: Manual check**

```bash
cd webapp && npm run app     # localhost:8000
```
Confirm: the compress switch toggles and the card-count updates (proving `$('compress').checked` still reads), the password field accepts input, and the target-tag select still drives the estimate.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/index.html
git commit -m "style(webapp): settings-row layout for the Archive panel"
```

---

### Task 6: Restore panel and archive-list rows

**Files:**
- Modify: `webapp/app/index.html` — `#panel-restore` markup; delete the old `#archives .arch` rules
- Modify: `webapp/app/ui/restore-view.ts`
- Modify: `webapp/test/restore-view.test.ts`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: the archive row shape, whose **child indices the test depends on**:
  ```
  row  (div.row, data-archive-id)
    ├─ children[0]  span.icon-tile
    ├─ children[1]  div.row-text     → children[0] = div.row-name  (the label)
    └─ children[2]  div.row-control  → children[0] = button.btn-tonal
  ```

- [ ] **Step 1: Update the test to the new structure (watch it fail)**

In `test/restore-view.test.ts`, every `children[0]!.children[1]!` that reaches the button becomes `children[0]!.children[2]!.children[0]!`. Apply to all four tests. For example, the first becomes:

```ts
  renderArchiveList(container, list, (id) => picks.push(id));
  const firstBtn = (container as unknown as StubEl).children[0]!.children[2]!.children[0]!;

  renderArchiveList(container, list, (id) => picks.push(id));
  const secondBtn = (container as unknown as StubEl).children[0]!.children[2]!.children[0]!;

  assert.strictEqual(firstBtn, secondBtn, 'Restore button must be reused, not recreated');
```

The behaviours asserted do not change: element reuse across re-renders, disabled state tracking completeness, re-labelling after a locale switch, and row removal. Only the path to the button moves.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/restore-view.test.js
```
Expected: FAIL — `children[2]` is undefined against the current flat row.

- [ ] **Step 3: Restructure the row in `restore-view.ts`**

Replace the row-construction block with:

```ts
    let row = existing.get(a.archiveId);
    if (row === undefined) {
      row = doc.createElement('div');
      row.className = 'row';
      row.setAttribute('data-archive-id', a.archiveId);

      const tile = doc.createElement('span');
      tile.className = 'icon-tile';
      tile.innerHTML = '<svg class="ico"><use href="#i-card"/></svg>';

      const text = doc.createElement('div');
      text.className = 'row-text';
      const name = doc.createElement('div');
      name.className = 'row-name';
      text.append(name);

      const control = doc.createElement('div');
      control.className = 'row-control';
      const btn = doc.createElement('button');
      btn.className = 'btn-tonal';
      // The row's archive id never changes, so binding it once is safe and keeps
      // the listener stable across updates.
      btn.addEventListener('click', () => onPick(a.archiveId));
      control.append(btn);

      row.append(tile, text, control);
      container.appendChild(row);
      existing.set(a.archiveId, row);
    }
```

Then update the per-render label writes to the new paths — these run on **every** render, not just creation, so a locale switch re-labels existing rows:

```ts
    const nameEl = (row.children[1] as HTMLElement).children[0] as HTMLElement;
    const btnEl = (row.children[2] as HTMLElement).children[0] as HTMLButtonElement;
    nameEl.textContent = label(a);
    btnEl.textContent = t.restore;
    btnEl.disabled = !a.complete;
```

The stub DOM in the test has no `innerHTML`. Add it to `StubEl` as a plain settable property (`innerHTML: string;` initialised to `''`) in both view tests' stubs — it is written but never read by assertions.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/restore-view.test.js
```
Expected: PASS.

- [ ] **Step 5: Replace the panel markup**

Delete the old `#archives .arch` and `#archives .arch button` CSS rules — the rows are `.row` inside a `.card` now.

```html
      <section id="panel-restore" role="tabpanel" hidden>
        <div style="margin-top:1.25rem">
          <button id="scan" class="btn-primary" disabled data-i18n="scanCards">Scan cards</button>
        </div>
        <div style="margin-top:0.5rem">
          <button id="stop-scan" class="btn-tonal" disabled style="width:100%;padding:14px" data-i18n="stop">Stop</button>
        </div>

        <span class="section-label" data-i18n="sectionArchives">Detected archives</span>
        <div class="card"><div id="archives"></div></div>

        <span class="section-label" data-i18n="sectionSettings">Settings</span>
        <div class="card">
          <div class="row">
            <span class="icon-tile"><svg class="ico"><use href="#i-save"/></svg></span>
            <div class="row-text"><div class="row-name" data-i18n="saveAs">save as</div></div>
            <div class="row-control"><input type="text" id="fname" value="restored.bin" /></div>
          </div>
        </div>

        <div class="status" id="restore-status" data-i18n="restoreIdle">Connect a Chameleon, then scan a pile of cards.</div>
      </section>
```

- [ ] **Step 6: Verify the full suite**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/restore-view.ts webapp/test/restore-view.test.ts
git commit -m "style(webapp): settings-row layout for the Restore panel and archive list"
```

---

### Task 7: Files panel and file-list rows

**Files:**
- Modify: `webapp/app/index.html` — `#panel-files` markup
- Modify: `webapp/app/ui/files-view.ts`
- Modify: `webapp/test/files-view.test.ts`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: the file row shape:
  ```
  row  (div.row, data-file-id)
    ├─ children[0]  span.icon-tile
    ├─ children[1]  div.row-text     → children[0] = div.row-name  (the label)
    └─ children[2]  div.row-control  → children[0] = button.btn-tonal (download)
                                        children[1] = button.btn-text  (delete)
  ```

- [ ] **Step 1: Update the test to the new structure (watch it fail)**

In `test/files-view.test.ts`, add `innerHTML: string;` to the `StubEl` interface and `innerHTML: '',` to the object literal in `makeDoc`. Then repoint every row-child access:

- label span: `row.children[0]` becomes `row.children[1]!.children[0]!`
- download button: `row.children[1]` becomes `row.children[2]!.children[0]!`
- delete button: `row.children[2]` becomes `row.children[2]!.children[1]!`

Every existing assertion is preserved — reuse across renders, listener survival, and re-labelling after a locale switch.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/files-view.test.js
```
Expected: FAIL against the current flat row.

- [ ] **Step 3: Restructure the row in `files-view.ts`**

```ts
    let row = existing.get(f.id);
    if (row === undefined) {
      row = doc.createElement('div');
      row.className = 'row';
      row.setAttribute('data-file-id', f.id);

      const tile = doc.createElement('span');
      tile.className = 'icon-tile';
      tile.innerHTML = '<svg class="ico"><use href="#i-folder"/></svg>';

      const text = doc.createElement('div');
      text.className = 'row-text';
      const name = doc.createElement('div');
      name.className = 'row-name';
      text.append(name);

      const control = doc.createElement('div');
      control.className = 'row-control';
      const dl = doc.createElement('button');
      dl.className = 'btn-tonal';
      dl.addEventListener('click', () => handlers.onDownload(f.id));
      const del = doc.createElement('button');
      del.className = 'btn-text';
      del.addEventListener('click', () => handlers.onDelete(f.id));
      control.append(dl, del);

      row.append(tile, text, control);
      container.appendChild(row);
      existing.set(f.id, row);
    }
    // Every label is rewritten on each render, not just at row creation: the
    // rows outlive a language switch, so button text would otherwise stay
    // frozen in the boot language forever.
    ((row.children[1] as HTMLElement).children[0] as HTMLElement).textContent = label(f);
    const controls = row.children[2] as HTMLElement;
    (controls.children[0] as HTMLElement).textContent = t.download;
    (controls.children[1] as HTMLElement).textContent = t.deleteBtn;
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd webapp && rm -rf dist && npx tsc && node --test dist/test/files-view.test.js
```
Expected: PASS.

- [ ] **Step 5: Replace the panel markup**

```html
      <section id="panel-files" role="tabpanel" hidden>
        <span class="section-label" data-i18n="sectionRestoredFiles">Restored files</span>
        <div class="card"><div id="files"></div></div>
        <p id="files-empty" class="muted" style="padding:0 4px" data-i18n="filesEmpty">No restored files yet. Restore an archive and it'll appear here.</p>
        <div style="display:flex;align-items:center;gap:0.6rem;padding:0 4px;margin-top:0.6rem">
          <span id="files-info" class="muted" style="flex:1;font-size:13px"></span>
          <button id="files-clear" class="btn-text" data-i18n="clearAll">Clear all</button>
        </div>
        <p id="files-status" class="muted" style="padding:0 4px;font-size:13px"></p>
      </section>
```

- [ ] **Step 6: Verify the full suite**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/files-view.ts webapp/test/files-view.test.ts
git commit -m "style(webapp): settings-row layout for the Files panel and file list"
```

---

### Task 8: Log, About and dialogs

**Files:**
- Modify: `webapp/app/index.html` — `#panel-log`, `#panel-about`, both `<dialog>` blocks, and their CSS
- Modify: `webapp/app/ui/about-panel.ts` — wrap rendered sections in `.card`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: nothing consumed downstream. This is the last task.

Per the spec, the Log stream and the Inspect dump stay **deliberately utilitarian**: monospace, dense, information-first. They inherit surface and radius tokens so they do not look foreign, and get no icon tiles.

- [ ] **Step 1: Replace the Log panel markup**

```html
      <section id="panel-log" role="tabpanel" hidden>
        <span class="section-label" data-i18n="sectionLogOptions">Log options</span>
        <div class="card">
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="logLevel">level</div></div>
            <div class="row-control">
              <select id="log-level">
                <option value="debug">debug</option>
                <option value="info" selected>info</option>
                <option value="warn">warn</option>
                <option value="error">error</option>
              </select>
            </div>
          </div>
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="autoScroll">auto-scroll</div></div>
            <div class="row-control">
              <label class="switch"><input type="checkbox" id="log-autoscroll" checked /><span class="switch-track"></span></label>
            </div>
          </div>
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="mirrorToConsole">mirror to console</div></div>
            <div class="row-control">
              <label class="switch"><input type="checkbox" id="log-console" /><span class="switch-track"></span></label>
            </div>
          </div>
          <div class="row" style="justify-content:flex-end;gap:4px">
            <button id="log-clear" class="btn-text" data-i18n="clear">Clear</button>
            <button id="log-copy" class="btn-text" data-i18n="copy">Copy</button>
            <button id="log-download" class="btn-text" data-i18n="download">Download</button>
          </div>
        </div>
        <div id="log"></div>
      </section>
```

Replace the old inline `style` on `#log` with a rule:

```css
#log {
  margin-top: 0.75rem; padding: 12px 14px;
  background: var(--surface); border-radius: var(--radius-sm); box-shadow: var(--shadow);
  font: 12px/1.45 ui-monospace, monospace;
  max-height: 60vh; overflow: auto; white-space: pre-wrap;
}
```

- [ ] **Step 2: Wrap the About sections in cards**

`render()` in `about-panel.ts` currently appends each section's `h3` and then its body paragraphs as **flat siblings** of `#about-content`. A CSS-only rule that cards each `<p>` would therefore split a two-line section into two separate cards. Group them in TS instead — replace the loop body in `render()`:

```ts
  for (const s of sections()) {
    const h = document.createElement('h3');
    h.className = 'section-label';
    h.textContent = s.h;
    container.appendChild(h);
    // One card per section, not per paragraph: the body lines belong together.
    const card = document.createElement('div');
    card.className = 'card about-card';
    for (const line of s.body) {
      const p = document.createElement('p');
      p.textContent = line;
      card.appendChild(p);
    }
    container.appendChild(card);
  }
```

`h3` reuses `.section-label` rather than defining a parallel style. The `muted` class moves off the paragraphs — the card body colour is set below. Add:

```css
#about-content { padding-top: 0.5rem; }
#about-content .section-label { margin-top: 1.25rem; }
.about-card { padding: 14px 18px; }
.about-card p { margin: 0 0 0.6rem; color: var(--text-secondary); font-size: 13px; }
.about-card p:last-child { margin-bottom: 0; }
```

There is no test covering `about-panel.ts`, so this change is verified only by the manual pass in Step 6.

- [ ] **Step 3: Restyle the dialogs**

```css
dialog {
  border: none; border-radius: var(--radius);
  background: var(--surface); color: var(--text);
  box-shadow: var(--shadow-md);
  padding: 1.25rem; max-width: 22rem; width: calc(100% - 2rem);
}
dialog::backdrop { background: rgba(0, 0, 0, 0.45); }
dialog p { margin: 0; }
.dialog-actions { display: flex; flex-direction: column; gap: 0.5rem; margin-top: 1rem; }
dialog.inspect { max-width: min(96vw, 62rem); max-height: 88vh; overflow: auto; }
.inspect-head { display: flex; align-items: baseline; gap: 0.6rem; flex-wrap: wrap; }
.inspect-actions { margin-left: auto; display: flex; gap: 0.4rem; }
dialog.inspect pre {
  overflow-x: auto; margin: 0.2rem 0 0.8rem;
  font: 12px/1.35 ui-monospace, monospace;
}
dialog.inspect h4 { margin: 0.6rem 0 0.1rem; font-size: 13px; }
```

In the overwrite dialog markup, the two overwrite buttons become `class="btn-primary"` and Skip becomes `class="btn-tonal"`. In the inspect dialog, the three action buttons become `class="btn-text"`. **All ids and `value` attributes are unchanged** — `archive-panel.ts` reads `overwriteDialog.returnValue` and matches `'all'` / `'once'`.

- [ ] **Step 4: Delete now-dead CSS**

Remove the leftover `.filled`, `#overwrite-skip`, `header` background and any other rule superseded by Tasks 1–8. Confirm nothing still references `.filled`:

```bash
cd webapp && grep -rn "filled" app/ && echo "FOUND — remove or repoint" || echo "clean"
```

- [ ] **Step 5: Verify**

```bash
cd webapp && rm -rf dist && npm test && npm run build:site
```
Expected: 289 passing, build verified.

- [ ] **Step 6: Full manual pass**

```bash
cd webapp && npm run app     # localhost:8000
```

Check every item; this is the only net for Global Constraint 1:

- [ ] Light and dark, via the system setting **and** the `◑` toggle (both must work)
- [ ] 360px width and desktop width
- [ ] Locale `ru` (longest strings) and `ka` (tallest glyphs): no clipped button text
- [ ] The tab strip scrolls horizontally rather than overflowing; selecting a tab off-screen scrolls it into view
- [ ] Every tab opens and its panel renders
- [ ] The compress switch toggles and the card-count estimate updates
- [ ] The overwrite dialog's three buttons return `once` / `all` / `skip`
- [ ] The Inspect dialog opens and its hex dump is still readable

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/about-panel.ts
git commit -m "style(webapp): restyle Log, About and dialogs; drop superseded CSS"
```

---

## Verification summary

| Gate | Command | Expected |
|---|---|---|
| Types and catalogues complete | `npx tsc` | clean |
| Behaviour unchanged | `rm -rf dist && npm test` | 289 passing |
| Deployable | `npm run build:site` | `site/ built and verified` |
| Markup keys resolve | included in `npm test` | `i18n.test.ts` green |
| IDs intact | manual pass, Task 8 Step 6 | every control responds |
