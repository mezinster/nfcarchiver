# Branded Tabbed Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the web app the NFC Archiver identity — a branded, themed, tabbed shell (Archive · Restore · Files · About) that re-homes the existing Archive and Restore features and adds an About/licensing/privacy tab.

**Architecture:** Vanilla TS + esbuild + CSS, no framework. The single imperative `app/main.ts` splits into a shell + per-tab panel modules over the unchanged, tested controllers; a single `ui/device.ts` owns the Chameleon transport and is the only app-side importer of the SDK.

**Tech Stack:** TypeScript 5, Node ≥ 22 (nvm), esbuild, CSS custom properties. No new runtime deps.

**Spec:** `docs/superpowers/specs/2026-07-28-webapp-branded-shell-design.md`.

## Global Constraints

- Branch: `webapp-branded-shell` (already checked out).
- Vanilla only — no framework, no component library, no new runtime dependencies.
- Dependency fence: `chameleon-ultra.js` may be imported ONLY in `webapp/src/transport/sdk-chameleon-device.ts` and `webapp/app/ui/device.ts` (the import moves out of `main.ts`). The core stays dependency-free.
- Branding: name "NFC Archiver"; seed `#1976D2`; light + dark (via `prefers-color-scheme` + a manual toggle stamping `data-theme` on `:root`, persisted to `localStorage`); 16px rounded cards, full-width filled buttons (16px radius), outlined inputs (12px).
- **Supported-tags copy must be web-accurate:** "Mifare Classic 1K (via Chameleon Ultra)" — NOT the Android app's NTAG/Ultralight text.
- Do NOT touch the tested modules (`controller.ts`, `estimate.ts`, `diagnostics.ts`, `src/**`). The 85 existing tests must stay green and `tsc` over the whole project must stay clean at every task boundary.
- Every npm/node command runs under Node LTS: prefix `source ~/.nvm/nvm.sh && nvm use --lts` and `rm -rf dist` before `npm test`.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Shared error-message helper + version constant

**Files:**
- Create: `webapp/app/ui/errors.ts`, `webapp/app/version.ts`
- Test: `webapp/test/errors.test.ts`

**Interfaces:**
- Consumes: error classes from `../src/transport/transport.js`, `../src/mifare/card-layout.js`, `../src/crypto.js`, and `../app/controller.js` (in errors.ts).
- Produces:
  - `humanError(e: unknown): string`
  - `APP_VERSION: string`

- [ ] **Step 1: Write the failing test**

`webapp/test/errors.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { humanError } from '../app/ui/errors.js';
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../src/transport/transport.js';
import { CardCapacityError } from '../src/mifare/card-layout.js';
import { DecryptionError } from '../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../app/controller.js';

test('humanError maps each typed error to a plain-language message', () => {
  assert.match(humanError(new CardAuthError('x')), /factory defaults/i);
  assert.match(humanError(new WriteVerifyError('x')), /verification failed/i);
  assert.match(humanError(new CardCapacityError('x')), /too large/i);
  assert.match(humanError(new TagTimeoutError('x')), /no card detected/i);
  assert.match(humanError(new NfarFormatError('x')), /no nfar archive/i);
  assert.match(humanError(new OverwriteRequiredError('x')), /already holds data/i);
  assert.match(humanError(new PasswordRequiredError('x')), /encrypted/i);
  assert.match(humanError(new DecryptionError('x')), /wrong password/i);
  assert.equal(humanError(new DOMException('Aborted', 'AbortError')), 'Cancelled.');
});

test('humanError falls back to the message for unknown errors', () => {
  assert.equal(humanError(new Error('boom')), 'boom');
  assert.equal(humanError('raw string'), 'raw string');
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: FAIL — TS2307: Cannot find module '../app/ui/errors.js'.

- [ ] **Step 3: Write the implementation**

`webapp/app/ui/errors.ts`:

```ts
/** Maps a caught error to a plain-language, user-facing message. */
import { CardAuthError, WriteVerifyError, TagTimeoutError } from '../../src/transport/transport.js';
import { CardCapacityError } from '../../src/mifare/card-layout.js';
import { DecryptionError } from '../../src/crypto.js';
import { OverwriteRequiredError, PasswordRequiredError, NfarFormatError } from '../controller.js';

export function humanError(e: unknown): string {
  if (e instanceof CardAuthError) return 'Card keys are not factory defaults — this card cannot be used.';
  if (e instanceof WriteVerifyError) return 'Write verification failed — move the card closer and retry.';
  if (e instanceof CardCapacityError) return 'A chunk is too large for a 1K card (internal error).';
  if (e instanceof TagTimeoutError) return 'No card detected — tap a card on the reader.';
  if (e instanceof NfarFormatError) return 'This card holds no NFAR archive data.';
  if (e instanceof OverwriteRequiredError) return 'This card already holds data.';
  if (e instanceof PasswordRequiredError) return 'This archive is encrypted — enter a password.';
  if (e instanceof DecryptionError) return 'Wrong password.';
  if (e instanceof DOMException && e.name === 'AbortError') return 'Cancelled.';
  return e instanceof Error ? e.message : String(e);
}
```

`webapp/app/version.ts`:

```ts
/** Web app version, shown in the About tab. Bump on release. */
export const APP_VERSION = '0.1.0';
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test
```

Expected: PASS (85 + 2 = 87 total).

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/errors.ts webapp/app/version.ts webapp/test/errors.test.ts
git commit -m "feat(webapp): shared humanError helper (tested) + APP_VERSION"
```

---

### Task 2: Branded shell — theme, app bar, device bar, tabs, panel markup

**Files:**
- Modify (rewrite): `webapp/app/index.html`, `webapp/app/main.ts`
- Create: `webapp/app/ui/shell.ts`, `webapp/app/ui/device.ts`

**Interfaces:**
- Consumes: `humanError` (Task 1); `ChameleonUltra`/`WebbleAdapter`/`Buffer` (SDK), `SdkChameleonDevice`, `ChameleonBleTransport`, `diagnoseCard`/`RawAntiColl`.
- Produces:
  - `initShell(): void` (tab switching + theme toggle)
  - `initDeviceBar(): void` (wires `#connect`, `#diagnose`, connection status)
  - `currentTransport(): ChameleonBleTransport | null`
  - `onConnectionChange(cb: (connected: boolean) => void): void`

After this task: the branded shell renders, tabs switch, the theme toggles, Connect and Diagnose work. The Archive/Restore inputs are visible but their action buttons stay **disabled** (their panels are wired in Tasks 3–4). `tsc`/bundle green; 85 tests unchanged.

- [ ] **Step 1: Rewrite index.html (branded shell + all panel markup)**

`webapp/app/index.html` (replace entire file):

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NFC Archiver</title>
    <style>
      :root {
        --primary: #1565c0; --on-primary: #fff; --primary-container: #d6e3ff; --on-primary-container: #001a41;
        --surface: #fdfcff; --surface-variant: #e1e2ec; --on-surface: #1a1c1e; --outline: #74777f;
        --error-container: #ffdad6; --on-error-container: #410002;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --primary: #a9c7ff; --on-primary: #002e69; --primary-container: #004494; --on-primary-container: #d6e3ff;
          --surface: #1a1c1e; --surface-variant: #43474e; --on-surface: #e3e2e6; --outline: #8e9199;
          --error-container: #93000a; --on-error-container: #ffdad6;
        }
      }
      :root[data-theme="light"] {
        --primary: #1565c0; --on-primary: #fff; --primary-container: #d6e3ff; --on-primary-container: #001a41;
        --surface: #fdfcff; --surface-variant: #e1e2ec; --on-surface: #1a1c1e; --outline: #74777f;
        --error-container: #ffdad6; --on-error-container: #410002;
      }
      :root[data-theme="dark"] {
        --primary: #a9c7ff; --on-primary: #002e69; --primary-container: #004494; --on-primary-container: #d6e3ff;
        --surface: #1a1c1e; --surface-variant: #43474e; --on-surface: #e3e2e6; --outline: #8e9199;
        --error-container: #93000a; --on-error-container: #ffdad6;
      }
      * { box-sizing: border-box; }
      body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--surface); color: var(--on-surface); }
      header { display: flex; align-items: center; gap: 0.6rem; padding: 0.8rem 1rem; background: var(--primary); color: var(--on-primary); }
      header h1 { font-size: 1.15rem; margin: 0; flex: 1; }
      header svg { width: 28px; height: 28px; fill: currentColor; }
      #theme-toggle { background: transparent; border: 1px solid currentColor; color: inherit; border-radius: 8px; cursor: pointer; padding: 0.3rem 0.6rem; }
      main { max-width: 40rem; margin: 0 auto; padding: 1rem; }
      button { font: inherit; }
      .filled { background: var(--primary); color: var(--on-primary); border: none; border-radius: 16px; padding: 0.8rem 1rem; width: 100%; cursor: pointer; }
      .filled:disabled { opacity: 0.45; cursor: default; }
      input[type="text"], input[type="password"], textarea { background: var(--surface); color: var(--on-surface); border: 1px solid var(--outline); border-radius: 12px; padding: 0.5rem 0.7rem; font: inherit; }
      textarea { width: 100%; }
      #device-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; padding: 0.6rem 1rem; background: var(--surface-variant); }
      #device-bar button { border-radius: 10px; border: 1px solid var(--outline); background: var(--surface); color: var(--on-surface); padding: 0.4rem 0.8rem; cursor: pointer; }
      #device-status { flex-basis: 100%; margin: 0; white-space: pre-wrap; font: 13px/1.4 ui-monospace, monospace; color: var(--on-surface); }
      #tabs { display: flex; border-bottom: 2px solid var(--surface-variant); }
      #tabs button { flex: 1; background: transparent; border: none; border-bottom: 2px solid transparent; margin-bottom: -2px; padding: 0.7rem 0.5rem; color: var(--on-surface); cursor: pointer; }
      #tabs button[aria-selected="true"] { color: var(--primary); border-bottom-color: var(--primary); font-weight: 600; }
      section[role="tabpanel"] { padding-top: 1rem; }
      section[hidden] { display: none; }
      .card { background: var(--surface); border: 1px solid var(--surface-variant); border-radius: 16px; padding: 1rem; margin: 0.6rem 0; }
      .status { padding: 0.6rem; border: 1px solid var(--surface-variant); border-radius: 12px; min-height: 1.4rem; white-space: pre-wrap; margin-top: 0.6rem; }
      .cardcount { font-size: 0.9rem; color: var(--outline); margin: 0.3rem 0; }
      progress { width: 100%; height: 1.1rem; vertical-align: middle; }
      .progress-label { display: block; font-size: 0.9rem; color: var(--outline); margin-top: 0.2rem; }
      #archives .arch { border: 1px solid var(--surface-variant); border-radius: 12px; padding: 0.5rem 0.7rem; margin: 0.4rem 0; display: flex; justify-content: space-between; align-items: center; gap: 0.6rem; }
      #archives .arch button { border-radius: 10px; border: 1px solid var(--outline); background: var(--primary-container); color: var(--on-primary-container); padding: 0.35rem 0.8rem; cursor: pointer; }
      #about-content h3 { margin: 1rem 0 0.3rem; }
      #about-content .muted { color: var(--outline); }
      label { display: inline-flex; align-items: center; gap: 0.35rem; }
    </style>
  </head>
  <body>
    <header>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zm-1 14H5V6h14v12zM7.5 9.5A1.5 1.5 0 0 1 9 8h6a1.5 1.5 0 0 1 1.5 1.5v5A1.5 1.5 0 0 1 15 16H9a1.5 1.5 0 0 1-1.5-1.5v-5zM9 9.5v5h6v-5H9z"/></svg>
      <h1>NFC Archiver</h1>
      <button id="theme-toggle" title="Toggle light/dark">◑</button>
    </header>

    <div id="device-bar">
      <button id="connect">Connect Chameleon</button>
      <span id="conn">disconnected</span>
      <button id="diagnose" disabled>Diagnose card</button>
      <pre id="device-status"></pre>
    </div>

    <main>
      <div id="tabs" role="tablist">
        <button role="tab" data-tab="archive" aria-selected="true">Archive</button>
        <button role="tab" data-tab="restore" aria-selected="false">Restore</button>
        <button role="tab" data-tab="files" aria-selected="false">Files</button>
        <button role="tab" data-tab="about" aria-selected="false">About</button>
      </div>

      <section id="panel-archive" role="tabpanel">
        <div class="card">
          <div><input type="file" id="file" /></div>
          <div style="margin-top:0.6rem"><label>or text:</label><br /><textarea id="text" rows="3" placeholder="Type text to archive as text_note.txt"></textarea></div>
          <div style="margin-top:0.6rem"><label><input type="checkbox" id="compress" checked /> compress</label>
            &nbsp;&nbsp;<label>password <input type="password" id="apass" placeholder="(optional)" /></label></div>
          <div id="cardcount" class="cardcount"></div>
          <button id="archive" class="filled" disabled>Archive to cards</button>
        </div>
        <div class="card" id="archive-progress-row" hidden><progress id="archive-bar"></progress><span id="archive-progress-label" class="progress-label"></span></div>
        <div class="status" id="archive-status">Connect a Chameleon, then choose a file or type text.</div>
      </section>

      <section id="panel-restore" role="tabpanel" hidden>
        <div class="card">
          <button id="scan" class="filled" disabled>Scan cards</button>
          <button id="stop-scan" class="filled" disabled style="margin-top:0.5rem">Stop</button>
          <div id="archives"></div>
          <div style="margin-top:0.6rem"><label>save as <input type="text" id="fname" value="restored.bin" /></label></div>
        </div>
        <div class="status" id="restore-status">Connect a Chameleon, then scan a pile of cards.</div>
      </section>

      <section id="panel-files" role="tabpanel" hidden>
        <div class="card"><p class="muted">No local history yet — archived files aren't stored in the browser in this version.</p></div>
      </section>

      <section id="panel-about" role="tabpanel" hidden>
        <div id="about-content"></div>
      </section>
    </main>
    <script type="module" src="./dist/main.js"></script>
  </body>
</html>
```

- [ ] **Step 2: Write device.ts (Chameleon state + connect + diagnose)**

`webapp/app/ui/device.ts`:

```ts
/**
 * Owns the Chameleon Ultra device/transport for the whole app — the single
 * place `chameleon-ultra.js` is imported on the app side. Panels read the
 * shared transport via currentTransport() and react to onConnectionChange().
 */

import { ChameleonUltra, Buffer } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../../src/transport/sdk-chameleon-device.js';
import { ChameleonBleTransport } from '../../src/transport/chameleon-ble.js';
import { diagnoseCard, type RawAntiColl } from '../diagnostics.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

let ultra: ChameleonUltra | null = null;
let transport: ChameleonBleTransport | null = null;
const listeners: Array<(connected: boolean) => void> = [];

export function currentTransport(): ChameleonBleTransport | null {
  return transport;
}

export function onConnectionChange(cb: (connected: boolean) => void): void {
  listeners.push(cb);
}

export function initDeviceBar(): void {
  const deviceStatus = $('device-status');

  $('connect').addEventListener('click', async () => {
    try {
      ultra = new ChameleonUltra();
      // use() is async (the adapter's install() runs availability checks etc.);
      // it MUST be awaited before connect(), or this.port is still undefined.
      await ultra.use(new WebbleAdapter());
      transport = new ChameleonBleTransport(new SdkChameleonDevice(ultra));
      await transport.connect();
      $('conn').textContent = 'connected';
      ($('diagnose') as HTMLButtonElement).disabled = false;
      for (const cb of listeners) cb(true);
      deviceStatus.textContent = 'Connected.';
    } catch (e) {
      deviceStatus.textContent = humanError(e);
    }
  });

  $('diagnose').addEventListener('click', async () => {
    if (!ultra) return;
    const dev = ultra;
    const raw: RawAntiColl = {
      async transceive(data, opts) {
        const resp = await dev.cmdHf14aRaw({
          data: Buffer.from(data),
          dataBitLength: opts?.dataBitLength ?? 0,
          activateRfField: opts?.activateRfField ?? false,
          keepRfField: opts?.keepRfField ?? false,
          checkResponseCrc: false,
          waitResponse: true,
        });
        return new Uint8Array(resp);
      },
    };
    deviceStatus.textContent = 'Hold the card on the reader…';
    try {
      const d = await diagnoseCard(raw);
      const verdict = d.isCascade
        ? '7-byte UID (cascade tag) — this is not a 4-byte Mifare Classic 1K.'
        : d.bccValid
          ? 'BCC OK — this card should work; the earlier error was likely transient positioning.'
          : 'BCC MISMATCH — malformed block-0 UID (a UID-writable "magic" card). Rewrite block 0 with a correct BCC, or use a standard Classic 1K.';
      deviceStatus.textContent =
        `ATQA: ${hex(d.atqa)}\n` +
        `UID (CL1): ${hex(d.uidCl1)}\n` +
        `BCC returned: 0x${d.bccReturned.toString(16).padStart(2, '0')}  computed: 0x${d.bccComputed.toString(16).padStart(2, '0')}\n` +
        verdict;
    } catch (e) {
      deviceStatus.textContent = `Diagnose failed: ${humanError(e)} (hold a card steady on the reader and retry)`;
    }
  });
}
```

- [ ] **Step 3: Write shell.ts (tabs + theme toggle)**

`webapp/app/ui/shell.ts`:

```ts
/** App shell: tab switching and the light/dark theme toggle. DOM glue only. */

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const TABS = ['archive', 'restore', 'files', 'about'] as const;

function activateTab(name: string): void {
  for (const t of TABS) {
    const btn = document.querySelector<HTMLButtonElement>(`#tabs button[data-tab="${t}"]`)!;
    const panel = $(`panel-${t}`);
    const selected = t === name;
    btn.setAttribute('aria-selected', String(selected));
    panel.hidden = !selected;
  }
}

function initTheme(): void {
  const saved = localStorage.getItem('nfar-theme');
  if (saved === 'light' || saved === 'dark') document.documentElement.setAttribute('data-theme', saved);
  $('theme-toggle').addEventListener('click', () => {
    const current = document.documentElement.getAttribute('data-theme')
      ?? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    const next = current === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    localStorage.setItem('nfar-theme', next);
  });
}

export function initShell(): void {
  for (const t of TABS) {
    document.querySelector<HTMLButtonElement>(`#tabs button[data-tab="${t}"]`)!
      .addEventListener('click', () => activateTab(t));
  }
  initTheme();
}
```

- [ ] **Step 4: Slim main.ts to an entry point**

`webapp/app/main.ts` (replace entire file):

```ts
/** Entry point: initialize the shell and the device bar. Panels are wired in later. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';

initShell();
initDeviceBar();
```

- [ ] **Step 5: Verify typecheck, tests, bundle, and the dependency fence**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-shell-check.js >/dev/null && echo BUNDLE OK
grep -rl "chameleon-ultra" app src --include="*.ts" | sort
```

Expected: 87 tests PASS, `tsc` clean, `BUNDLE OK`. The grep lists exactly `app/ui/device.ts`, `src/transport/chameleon-device.ts` (doc comment), and `src/transport/sdk-chameleon-device.ts` — NOT `app/main.ts`.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/index.html webapp/app/main.ts webapp/app/ui/shell.ts webapp/app/ui/device.ts
git commit -m "feat(webapp): branded tabbed shell — theme, app bar, device bar, tabs; device.ts owns the SDK"
```

---

### Task 3: Archive panel

**Files:**
- Create: `webapp/app/ui/archive-panel.ts`
- Modify: `webapp/app/main.ts` (add `initArchivePanel()`)

**Interfaces:**
- Consumes: `currentTransport`/`onConnectionChange` (Task 2); `ArchiveController`, `OverwriteRequiredError`, `TagTimeoutError` (`../controller.js`); `estimateCardCount` (`../estimate.js`); `humanError` (Task 1). Uses DOM ids from index.html: `#file`, `#text`, `#compress`, `#apass`, `#cardcount`, `#archive`, `#archive-progress-row`, `#archive-bar`, `#archive-progress-label`, `#archive-status`.
- Produces: `initArchivePanel(): void`.

- [ ] **Step 1: Write the archive panel**

`webapp/app/ui/archive-panel.ts`:

```ts
/** Archive tab: file/text source, live card counter, write-and-verify with progress. */
import { ArchiveController, OverwriteRequiredError } from '../controller.js';
import { TagTimeoutError } from '../../src/transport/transport.js';
import { estimateCardCount } from '../estimate.js';
import { currentTransport, onConnectionChange } from './device.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

export function initArchivePanel(): void {
  const setStatus = (msg: string) => { $('archive-status').textContent = msg; };
  const bar = $('archive-bar') as HTMLProgressElement;
  const showProgress = (label: string, value: number | null, max: number) => {
    $('archive-progress-row').hidden = false;
    bar.max = max;
    if (value === null) bar.removeAttribute('value'); else bar.value = value;
    $('archive-progress-label').textContent = label;
  };
  const hideProgress = () => { $('archive-progress-row').hidden = true; };

  let fileBytes: Uint8Array | null = null;
  let fileName = '';
  const currentSource = (): { data: Uint8Array; fileName: string } | null => {
    if (fileBytes) return { data: fileBytes, fileName };
    const text = ($('text') as HTMLTextAreaElement).value;
    if (text.length > 0) return { data: new TextEncoder().encode(text), fileName: 'text_note.txt' };
    return null;
  };

  let counterTimer: ReturnType<typeof setTimeout> | undefined;
  const updateCounter = async (): Promise<void> => {
    const src = currentSource();
    const el = $('cardcount');
    if (!src) { el.textContent = ''; return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
    el.textContent = `≈ ${await estimateCardCount(src.data, src.fileName, { compress, encrypted })} card(s)`;
  };
  const scheduleCounter = () => { clearTimeout(counterTimer); counterTimer = setTimeout(updateCounter, 200); };

  $('file').addEventListener('change', async () => {
    const f = ($('file') as HTMLInputElement).files?.[0];
    fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
    fileName = f?.name ?? '';
    updateCounter();
  });
  for (const id of ['text', 'compress', 'apass']) $(id).addEventListener('input', scheduleCounter);

  onConnectionChange((connected) => {
    ($('archive') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus('Choose a file or type text, then Archive to cards.');
  });

  $('archive').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const src = currentSource();
    if (!src) { setStatus('Pick a file or type some text first.'); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const pass = ($('apass') as HTMLInputElement).value;
    const ctrl = new ArchiveController(transport);
    const render = (written: number, total: number, done: boolean) => {
      showProgress(
        done ? `✓ ${written} of ${total} cards written & verified` : `✓ ${written} of ${total} written & verified — tap the next card`,
        written, total,
      );
      setStatus(done ? `Done — wrote and verified ${written} card(s).` : `Tap card ${written + 1} of ${total} on the reader…`);
    };
    try {
      const total = await ctrl.prepare({ data: src.data, fileName: src.fileName, compress, password: pass || undefined });
      render(0, total, false);
      let done = false;
      while (!done) {
        try {
          const res = await ctrl.writeNextCard();
          done = res.done;
          render(res.progress.written, total, done);
        } catch (e) {
          if (e instanceof TagTimeoutError) { setStatus('No card detected — tap a card (hold it a few mm off)…'); continue; }
          if (e instanceof OverwriteRequiredError) {
            if (confirm('This card already holds data. Overwrite it?')) {
              const res = await ctrl.writeNextCard(undefined, true);
              done = res.done;
              render(res.progress.written, total, done);
            } else { setStatus('Skipped. Tap a different card…'); }
          } else { throw e; }
        }
      }
    } catch (e) {
      hideProgress();
      setStatus(humanError(e));
    }
  });
}
```

- [ ] **Step 2: Wire it into main.ts**

`webapp/app/main.ts` (add the import and call):

```ts
/** Entry point: initialize the shell, device bar, and panels. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';

initShell();
initDeviceBar();
initArchivePanel();
```

- [ ] **Step 3: Verify**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-arch-check.js >/dev/null && echo BUNDLE OK
```

Expected: 87 tests PASS, `tsc` clean, `BUNDLE OK`.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/ui/archive-panel.ts webapp/app/main.ts
git commit -m "feat(webapp): archive panel (file/text, counter, write-verify) in the shell"
```

---

### Task 4: Restore panel

**Files:**
- Create: `webapp/app/ui/restore-panel.ts`
- Modify: `webapp/app/main.ts` (add `initRestorePanel()`)

**Interfaces:**
- Consumes: `currentTransport`/`onConnectionChange` (Task 2); `RestoreController`, `PasswordRequiredError`, `type DetectedArchive` (`../controller.js`); `TagTimeoutError` (`../../src/transport/transport.js`); `DecryptionError` (`../../src/crypto.js`); `humanError` (Task 1). DOM ids: `#scan`, `#stop-scan`, `#archives`, `#fname`, `#restore-status`.
- Produces: `initRestorePanel(): void`.

- [ ] **Step 1: Write the restore panel**

`webapp/app/ui/restore-panel.ts`:

```ts
/** Restore tab: scan a pile of cards, detect archives, pick a complete one to restore. */
import { RestoreController, PasswordRequiredError, type DetectedArchive } from '../controller.js';
import { TagTimeoutError } from '../../src/transport/transport.js';
import { DecryptionError } from '../../src/crypto.js';
import { currentTransport, onConnectionChange } from './device.js';
import { humanError } from './errors.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function renderArchives(list: DetectedArchive[], onPick: (id: string) => void): void {
  const container = $('archives');
  container.innerHTML = '';
  for (const a of list) {
    const row = document.createElement('div');
    row.className = 'arch';
    const label = document.createElement('span');
    label.textContent = `Archive ${a.shortId}…  ${a.isEncrypted ? '🔒 encrypted' : 'unencrypted'}  ·  ${a.received} / ${a.totalChunks} card(s)${a.complete ? ' ✓' : ''}`;
    const btn = document.createElement('button');
    btn.textContent = 'Restore';
    btn.disabled = !a.complete;
    btn.addEventListener('click', () => onPick(a.archiveId));
    row.append(label, btn);
    container.appendChild(row);
  }
}

export function initRestorePanel(): void {
  const setStatus = (msg: string) => { $('restore-status').textContent = msg; };
  let scanAbort: AbortController | null = null;

  onConnectionChange((connected) => {
    ($('scan') as HTMLButtonElement).disabled = !connected;
    if (connected) setStatus('Scan a pile of cards to detect archives.');
  });

  $('scan').addEventListener('click', async () => {
    const transport = currentTransport();
    if (!transport) return;
    const ctrl = new RestoreController(transport);
    scanAbort = new AbortController();
    let pickedId: string | null = null;
    ($('scan') as HTMLButtonElement).disabled = true;
    ($('stop-scan') as HTMLButtonElement).disabled = false;
    setStatus('Scanning — tap cards on the reader…');
    const onPick = (id: string) => {
      pickedId = id;
      $('archives').querySelectorAll('button').forEach((b) => { (b as HTMLButtonElement).disabled = true; });
      scanAbort?.abort();
    };

    try {
      try {
        for (;;) {
          try {
            const list = await ctrl.scanNextCard(scanAbort.signal);
            renderArchives(list, onPick);
            setStatus(`Detected ${list.length} archive(s). Tap more cards, or Restore a complete one.`);
          } catch (e) {
            if (e instanceof TagTimeoutError) continue;
            if (e instanceof DOMException && e.name === 'AbortError') break;
            throw e;
          }
        }
      } catch (e) {
        setStatus(humanError(e));
        return;
      }

      if (!pickedId) { setStatus('Stopped scanning.'); return; }
      const chosenId = pickedId;

      try {
        let pw: string | undefined;
        let result: { data: Uint8Array; fileName: string | null } | undefined;
        for (let attempt = 0; attempt < 5; attempt++) {
          try { result = await ctrl.restore(chosenId, pw); break; }
          catch (e) {
            if (e instanceof PasswordRequiredError || e instanceof DecryptionError) {
              const entered = prompt(e instanceof DecryptionError ? 'Wrong password. Enter password:' : 'This archive is encrypted. Enter password:') ?? undefined;
              if (entered === undefined) { setStatus('Cancelled.'); return; }
              pw = entered; continue;
            }
            throw e;
          }
        }
        if (!result) { setStatus('Too many failed password attempts.'); return; }
        const name = result.fileName ?? (($('fname') as HTMLInputElement).value || 'restored.bin');
        if (result.fileName) ($('fname') as HTMLInputElement).value = result.fileName;
        const a = document.createElement('a');
        a.href = URL.createObjectURL(new Blob([result.data as BlobPart]));
        a.download = name;
        a.click();
        URL.revokeObjectURL(a.href);
        setStatus(`Restored ${result.data.length} bytes → ${name}.`);
      } catch (e) {
        setStatus(humanError(e));
      }
    } finally {
      ($('stop-scan') as HTMLButtonElement).disabled = true;
      ($('scan') as HTMLButtonElement).disabled = false;
    }
  });

  $('stop-scan').addEventListener('click', () => scanAbort?.abort());
}
```

- [ ] **Step 2: Wire it into main.ts**

`webapp/app/main.ts` (add the import and call):

```ts
/** Entry point: initialize the shell, device bar, and panels. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';
import { initRestorePanel } from './ui/restore-panel.js';

initShell();
initDeviceBar();
initArchivePanel();
initRestorePanel();
```

- [ ] **Step 3: Verify**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-rest-check.js >/dev/null && echo BUNDLE OK
```

Expected: 87 tests PASS, `tsc` clean, `BUNDLE OK`.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/ui/restore-panel.ts webapp/app/main.ts
git commit -m "feat(webapp): restore panel (scan-then-pick multi-archive) in the shell"
```

---

### Task 5: About panel

**Files:**
- Create: `webapp/app/ui/about-panel.ts`
- Modify: `webapp/app/main.ts` (add `initAboutPanel()`)

**Interfaces:**
- Consumes: `APP_VERSION` (Task 1). DOM id: `#about-content`.
- Produces: `initAboutPanel(): void`.

- [ ] **Step 1: Write the About panel**

`webapp/app/ui/about-panel.ts`:

```ts
/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION } from '../version.js';

const SECTIONS: Array<{ h: string; body: string[] }> = [
  { h: 'NFC Archiver', body: [
    `Web version ${APP_VERSION}`,
    'A distributed data archive system using NFC tags. Store files across multiple tags and restore them later — fully in your browser.',
  ] },
  { h: 'Supported tags', body: [
    'Mifare Classic 1K, via a Chameleon Ultra over Web Bluetooth.',
    '(NTAG / MIFARE Ultralight via the phone’s own NFC will come with the future Web NFC support.)',
  ] },
  { h: 'Privacy', body: [
    'Everything runs client-side. Your files, text, and passwords never leave the browser — there is no server, no upload, and no tracking.',
  ] },
  { h: 'Open-source licenses', body: [
    'NFC Archiver — MIT License © 2026 mezinster.',
    'chameleon-ultra.js — MIT License.',
  ] },
];

export function initAboutPanel(): void {
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
  for (const s of SECTIONS) {
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
```

- [ ] **Step 2: Wire it into main.ts**

`webapp/app/main.ts` (final form):

```ts
/** Entry point: initialize the shell, device bar, and panels. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';
import { initRestorePanel } from './ui/restore-panel.js';
import { initAboutPanel } from './ui/about-panel.js';

initShell();
initDeviceBar();
initArchivePanel();
initRestorePanel();
initAboutPanel();
```

- [ ] **Step 3: Verify (full gate)**

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && rm -rf dist && npm test && npx tsc --noEmit && npx esbuild app/main.ts --bundle --format=esm --outfile=/tmp/nfar-about-check.js >/dev/null && echo BUNDLE OK
```

Expected: 87 tests PASS, `tsc` clean, `BUNDLE OK`.

- [ ] **Step 4: Commit**

```bash
git add webapp/app/ui/about-panel.ts webapp/app/main.ts
git commit -m "feat(webapp): About panel — description, supported tags, licenses, privacy"
```

---

## Completion Criteria

- `npm test` in `webapp/` passes (87 tests) on Node LTS.
- `npx tsc --noEmit` clean; `npx esbuild app/main.ts --bundle` succeeds.
- Dependency fence: `chameleon-ultra.js` imported only in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts` (plus a doc-comment mention in `chameleon-device.ts`).
- Manual check (`npm run app`, browser on the Bluetooth host): the branded shell renders; tabs switch; the theme toggle flips light/dark and persists; Connect + Diagnose work; Archive and Restore function end-to-end against a real Chameleon; the About tab shows the web-accurate content.
- Core/controllers/estimate/diagnostics unchanged; no new runtime dependencies.
