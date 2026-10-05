# Webapp redesign: Material 3 bottom-nav shell + card-slot stage ("B + C")

**Date:** 2026-10-05
**Scope:** `webapp/app/` — `index.html` (tokens, CSS, markup), `app/ui/*` view builders and panel adapters, one new view module, the seven i18n catalogues. One behaviour addition in `app/ui/archive-orchestrator.ts` (archive Stop). No change to `src/` (the dependency-free core), to any transport, to the NFAR format, to on-tag bytes, or to the Flutter app.

**Supersedes** decision 2 of `2026-07-31-webapp-ui-refactor-design.md` ("segmented control at the top, not a bottom navigation bar"). That was right for a reskin; this is a redesign whose explicit goal is to read like the Flutter app on a phone, and a phone with five peer destinations wants an M3 navigation bar. Do not "restore" the top segmented strip on compact widths.

## Goal

Make the web app feel like the Flutter app's sibling — same Material 3 palette, shapes and vocabulary — and fix the UX at the one moment that matters: tapping cards. Today writing and scanning are a bare `<progress>` and a sentence; after this change the user sees each card as a slot (written / writing / waiting) and is told exactly what to do next.

## Design source

Designed on Superdesign, project **NFC Archiver Web — redesign**
(<https://superdesign.dev/teams/9309852a-c600-4c0e-b7f1-021c835ff017/projects/fa2ba3db-0494-4739-abfd-3fb31d66d5a1>). Local context lives in the git-excluded `.superdesign/` (init files, `design-system.md`, `resume.json`).

| Tile | Draft id | Role |
|---|---|---|
| 0 · BASELINE | `12246d8d-6bf3-4a93-9d45-94ef95ee1e05` | faithful reproduction of today's Archive tab |
| A · HOME HUB | `e578541c-323e-49f7-bf21-a640d3a29b43` | rejected direction (hub + wizard) |
| C · WRITE STAGE | `0f39773d-a973-4953-b5c0-1579a3ce2c64` | source of the stage idiom |
| **B+C · 1 ARCHIVE idle** | `09bb8167-470d-4aee-8ef6-d502e1f4c791` (v2) | **reference for the shell and Archive** |
| B+C · 2 ARCHIVE writing | `9ddf7f45-f523-429d-83e9-4b79dda61f3e` | write stage |
| B+C · 3 overwrite prompt | `f7d828f8-9597-48e9-bbab-826fe9e9f932` (v2) | overwrite dialog over the stage |
| B+C · 4 RESTORE scanning | `c5761880-332c-4ac6-9efc-499cb78e6808` | scan stage + archive rows |
| B+C · 5 FILES | `03e3f0cd-dcd6-41aa-b313-36cffe1509e5` | files list + empty state |
| B+C · 6 LOG | `f129e8e0-d946-4e96-910f-c9ef5feb4a1c` | log options + log |
| B+C · 7 ABOUT | `73456e05-beae-4ec5-9783-f77794913bf5` (v2) | about |
| B+C · 8 no reader | `c9095f99-b545-4e2c-bd35-130d95e8a2ff` (v2) | first-run / disconnected |
| B+C · 9 INSPECT | `4ad60c49-4bb2-4dcc-9178-6a2df8c05138` | full-screen inspector |
| B+C · 10 dark | `7c3fac0f-072e-4c03-8adc-85c39ad49c2b` | dark-theme check |

The drafts are references, not copy-paste sources: they are Tailwind + inline HTML, while the app is one hand-written stylesheet. Where a draft and this spec disagree, **this spec wins** — the known draft defects are listed under each section.

## Decisions (confirmed with user)

1. **Direction B + C**: single page, five destinations, M3 look (B), with C's card-slot stage as the in-progress state of Archive and Restore.
2. **Flutter M3 palette** from seed `#1976D2` (tonal-spot ⇒ primary `#415F91`, not today's brighter `#0061a4`).
3. **Archive gets a real Stop** (an `AbortSignal` threaded through the write loop).
4. **Navigation**: M3 bottom navigation bar on compact widths; at **≥ 840px** the same markup moves under the app bar as a centred tab row (CSS only).

## Hard constraints (carried from the code)

- **Every element id survives.** `test/markup-ids.test.ts` asserts every `$('…')`/`getElementById('…')` id exists in `index.html`, that `#tabs` contains `button[data-tab]` for all five tabs with one `aria-selected="true"`, that no author rule sets `display` on a closable `dialog`, that no dialog is its own scroll container, and that every `<use href>` symbol exists. All stay green; new ids are added, none renamed.
- **Row skeleton survives.** `restore-view.test.ts` and `files-view.test.ts` reach into `row.children[1].children[0]` (label) and `row.children[2].children[n]` (buttons) and compare button `textContent` to the catalogue. Rows stay *icon tile / text / control*; buttons keep their translated text as `textContent` even when they render as icon buttons (label in a visually hidden span, icon `<svg>` contributes no text).
- **No webfont fetch.** Font stack `Roboto, system-ui, sans-serif`. The About page promises "no server, no upload, and no tracking"; a font CDN would break that silently. Android ships Roboto.
- **Seven locales.** Every new string goes into `en.ts` and all six translations (`tsc` enforces it). RU/KA/UK run ~40% longer than EN: nothing may rely on a label fitting one line at 360px.
- **The dependency fence holds** — nothing new imports `chameleon-ultra.js`.

## 1 · Tokens

Replace the four token blocks (`:root`, `@media (prefers-color-scheme: dark)`, `[data-theme="light"]`, `[data-theme="dark"]`) with M3 roles. Names follow M3 so CSS reads like the Flutter theme:

| Token | Light | Dark |
|---|---|---|
| `--primary` / `--on-primary` | `#415F91` / `#FFFFFF` | `#AAC7FF` / `#0A305F` |
| `--primary-container` / `--on-primary-container` | `#D6E3FF` / `#001B3E` | `#284777` / `#D6E3FF` |
| `--secondary-container` / `--on-secondary-container` | `#DAE2F9` / `#121C2B` | `#3E4759` / `#DAE2F9` |
| `--surface` (page) | `#F9F9FF` | `#111318` |
| `--surface-container-low` (cards) | `#F3F3FA` | `#191C20` |
| `--surface-container` (nav bar) | `#EDEDF4` | `#1D2024` |
| `--surface-container-high` (inputs, dialogs, CTA card) | `#E7E8EE` | `#282A2F` |
| `--on-surface` / `--on-surface-variant` | `#191C20` / `#44474E` | `#E2E2E9` / `#C4C6D0` |
| `--outline` / `--outline-variant` | `#74777F` / `#C4C6D0` | `#8E9099` / `#44474E` |
| `--error` / `--error-container` / `--on-error-container` | `#BA1A1A` / `#FFDAD6` / `#410002` | `#FFB4AB` / `#93000A` / `#FFDAD6` |
| `--success` / `--success-container` | `#2E7D52` / `#E6F4ED` | `#7FD8A4` / `#10331F` |
| `--warning` | `#B76E00` | `#F0B357` |
| `--elev-1` | `0 1px 2px rgba(0,0,0,.12), 0 1px 3px 1px rgba(0,0,0,.06)` | `none` (tone separates) |

Shape: cards 16, inputs 12, filled/outlined full-width buttons 16 at min-height 56, compact buttons 20 (pill) at height 40, dialogs 28, icon tiles 12 at 48px. Type scale per `.superdesign/design-system.md` (title-large 22/28, title-medium 16/24 500, body-medium 14/20, body-small 12/16, label-large 14/20 500, section label 11/16 500 uppercase). Spacing on a 4-pt grid; page gutter 16. Content column stays `max-width: 36rem`.

Every interactive target ≥ 48×48 (icon buttons get a 48px hit box around a 24px glyph). `prefers-reduced-motion` disables the pulse and progress transitions.

## 2 · Shell

**App bar** (`<header>`): centred title "NFC Archiver"; `#lang` and `#theme-toggle` become 48px icon buttons left/right. `#lang` stays a `<select>` (it is the language list), styled as an icon button with the current locale's code visible — a native select keeps keyboard and screen-reader behaviour for free.

**Reader card** (`#device-bar`, reshaped; all six ids kept: `device-pill`, `conn`, `connect`, `use-web-nfc`, `inspect`, `disconnect`, `device-status`):

- *Connected* (draft 1): primary-container card on one line — reader glyph (bluetooth for Chameleon, nfc for phone), reader name as title-medium, `#conn` as supporting text with the green dot, then tonal `#inspect` and a 48px `#disconnect` icon button (link-off glyph, translated label visually hidden). `#connect`/`#use-web-nfc` hidden. No overflow menu.
- *Disconnected* (draft 8): surface-container-high CTA — 48px tile, title "Connect a reader", body text, then filled `#connect` and outlined `#use-web-nfc` (still `hidden` unless `webNfcAvailable()`). The two buttons sit on one row when both fit and **wrap to a stack otherwise** (`flex-wrap`, each `flex: 1 1 12rem`) — draft 8 squeezes "Connect Chameleon" onto two lines at 390px, which this rule forbids.
- `#device-status` messages (`readerDisconnectedClickConnect`, etc.) render as the card's supporting line instead of a separate monospace `<pre>`.
- The card's state is driven by the existing `data-connected` attribute that `device.ts:renderConn()` already sets — CSS keys off `#device-pill[data-connected="true"]`, so the switch needs no new TS state. Which glyph/name to show comes from `activeReaderName()`, already exported by `device.ts`.

**Navigation** (`#tabs`, `role="tablist"`): M3 navigation bar fixed to the bottom on compact widths — five destinations with outlined 24px icons and labels, active indicator pill (secondary-container) on the selected item only. `<main>` gets bottom padding equal to the bar height plus `env(safe-area-inset-bottom)`. At `min-width: 840px` the bar becomes static, sits under the app bar, and the icons collapse to a centred tab row. `shell.ts` keeps working unchanged; its `scrollIntoView` call becomes a no-op on a non-scrolling bar and may stay. Labels must survive RU/KA at 360px: label font 12px, single line, `text-overflow: ellipsis` as last resort, never wrapping under the icon.

## 3 · Archive

### Idle (drafts 1, 8)

- **Source**: M3 segmented button `File | Text` (new `#source-file-btn`, `#source-text-btn`, `role="radiogroup"` semantics via `aria-pressed`). **Behaviour change:** `currentSource()` returns the source of the *selected mode* instead of "the file if one is chosen, else the text". Switching mode re-runs the estimate. Default mode: File.
- **File mode**: `#file` stays the real `<input type="file">`, visually hidden inside a `<label>` card. Empty: upload glyph, "Tap to choose a file". Chosen: file tile, name (ellipsized), human size, success check, "Tap to change".
- **Text mode**: `#text` as a filled-outlined multi-line field with helper "Saved as text_note.txt" (`subTypeText` already exists).
- **Settings card**: "Tag type" label above a full-width `#target-tag` select (fixes the baseline's crushed label column); `#compress` switch row; "Password (optional)" label above `#apass` with a lock glyph. Then `#cardcount` as the **estimate panel** — primary-container, radius 12, title-medium line "≈ N cards needed" and a body-small line with the tag type and, under Auto-detect, "adapts to the tapped card". Empty when there is no source (panel hidden, not blank).
- **Primary action**: `#archive` filled 56px with an NFC glyph, `position: sticky` at the bottom of the panel above the nav bar, on an **opaque surface backing strip** — a disabled (38%) button must never show content through itself (draft 8 defect). When disabled because no reader is connected, a helper line under it reads "Connect a reader first"; when disabled because the reader is busy, the existing `readerBusyElsewhere` title remains.
- `#archive-status` becomes the panel's polite live region (`role="status"`); errors get the error-container treatment via a `data-tone="error"` attribute set by the panel.

### Writing (drafts 2, 3)

When the write loop starts, `#panel-archive` gets `data-state="writing"`: source and settings cards hide, **`#archive-stage`** shows (it replaces `#archive-progress-row`; `#archive-bar` and `#archive-progress-label` move inside it and keep their ids):

- **Slot row** (`#archive-slots`): one slot per card — *written* (primary fill, check), *current* (primary-container, outline, NFC glyph, gentle pulse), *waiting* (dashed outline), *warning* (error-container, alert glyph — while the overwrite dialog is open). Each slot shows "Card n" and its state word.
- **Headline** from the orchestrator's existing status text (`tapCardOf` / `writingCard`), title-large, centred, plus a supporting line.
- **Progress**: the native `<progress>` stays (indeterminate state is expressed by removing `value`, which a div cannot), restyled as an M3 linear indicator, label "Card n of N" + percentage.
- **Summary card**: file tile, name, "size · GZIP · AES-256 · tag type" — read-only while writing.
- **Stop**: new `#archive-stop`, outlined full-width with a filled stop-square glyph (draft 2 shows a checkbox glyph — wrong).
- **Done**: all slots written, headline `archiveDone`, Stop replaced by **`#archive-again`** "Archive another", which clears `data-state` and returns to the idle form with the source kept.
- **Stopped / failed**: slots keep their state, status shows `cancelled` or the human error, and `#archive-again` reads "Back" (same element, label from the catalogue).

**Many cards.** The slot row is for small archives. Above **10** cards it is replaced by a compact counter ("Card 7 of 24") and the progress bar alone; slots never wrap into a grid or scroll horizontally.

**Changing totals.** Under Auto-detect the orchestrator may re-chunk mid-write (`res.rechunkedTo`), changing `total`. The stage re-renders on any change of `max`, not only `value`.

**Overwrite dialog** (`#overwrite-dialog`, draft 3): M3 basic dialog, radius 28, surface-container-high, title "Card already holds data", existing message, stacked actions filled Overwrite / tonal Overwrite all remaining / text Skip. While open, the current slot shows *warning*. Draft 3's progress label peeks out beside the dialog; the scrim (`::backdrop`) must cover the page fully.

### New module: `app/ui/stage-view.ts`

Pure DOM builder, same pattern and test style as `restore-view.ts`:

```ts
export type SlotState = 'written' | 'current' | 'waiting' | 'warning';
export function renderSlots(container: HTMLElement, written: number, total: number,
                            opts: { warning?: boolean }): void;
```

Reconciles in place (slots keyed by index, created/removed only when `total` changes), relabels on every call (locale switches), and renders the compact counter instead of slots when `total > 10`. Unit-tested with the stub DOM from `restore-view.test.ts`: slot count follows `total`; states by position; re-chunk shrinks/grows the row; `warning` marks only the current slot; > 10 switches to the counter; relabel after `setLocale`.

## 4 · Archive Stop (behaviour)

`ArchiveOrchestrator.run(transport, opts, signal?: AbortSignal)`:

- passes `signal` to every `ctrl.writeNextCard(signal, …)` call (both the normal and the overwrite-retry path);
- `awaitReconnect` rejects with `AbortError` when the signal aborts (the panel wires it);
- an abort while the overwrite prompt is open closes `#overwrite-dialog` (the panel listens on the signal); whatever `confirmOverwrite` then resolves, the loop checks `signal.aborted` **before** acting on the choice and takes the `AbortError` path — an abort is never read as Skip and never writes another card;
- the existing `AbortError` branch (currently commented "unreachable today") becomes live: status `cancelled`, log `Write cancelled`, return. No pacing before the check — that ordering is already in place and must stay.

Cards written before Stop stay valid NFAR chunks; the archive is simply incomplete, exactly like stopping halfway by walking away today. The status line says so (new key `archiveStoppedPartial(written, total)`).

TDD in `test/archive-orchestrator.test.ts` with the fake transport: abort while waiting for a tap; abort while the overwrite prompt is open; abort while awaiting reconnect; abort never retried or counted by the breaker; written cards untouched.

## 5 · Restore (draft 4)

- Idle: `#scan` filled 56px; the "Detected archives" card shows only if it has rows.
- Scanning (reader lock owner `scan`): `#panel-restore` gets `data-state="scanning"`; new `#restore-stage` shows a pulsing reader glyph in a primary-container circle, headline "Tap cards in any order", and the live `#restore-status` text; `#stop-scan` becomes the outlined Stop. The panel already computes this from `readerLock` in `syncButtons()` — set the attribute there.
- Archive rows (`restore-view.ts`): text column becomes two lines — monospace short id + lock glyph if encrypted; slot dots (≤ 10, else omitted) + "k/N cards", "complete" in success colour. Control stays one tonal Restore button (`children[2].children[0]`), disabled until complete. The single `archiveRow` string splits into `archiveRowStatus(received, total, complete)`; the id renders raw.
- `#fname` as an outlined field labelled "Save as" with the existing helper.

## 6 · Files, Log, About, Inspect

- **Files** (draft 5): rows = 48px file tile, name (ellipsized, never pushed out by buttons), meta "size · n cards · date" + lock glyph; controls = Download and Delete as **icon buttons** (labels visually hidden, so `textContent` still equals `download`/`deleteBtn` for the existing tests). Footer: `#files-info` left, `#files-clear` as an error-coloured text button right. `#files-empty` becomes an empty-state card with a folder glyph.
- **Log** (draft 6): options card rows (level select, two switches) and an icon+text action row (Clear / Copy / Download); `#log` on surface-container-high, radius 12, 12px monospace; rows get `data-level` colour (`warn` → `--warning`, `error` → `--error`) — the attribute is already set by `log-panel.ts`. Stays a utilitarian instrument (decision 4 of the July spec holds).
- **About** (draft 7 v2): header block — 64px brand tile, name, `aboutWebVersion`, `aboutDescription` — then one card per section with an uppercase section label. Strings exactly as in the catalogue; no new links.
- **Inspect** (draft 9): below 600px the dialog is full-screen (width/height 100dvh, radius 0, top bar with close ✕ and Copy/Download text buttons); above, the current centred modal. Identity and NFAR render as key/value rows; CRC result as a success/error chip; raw hex stays a horizontally scrolling `<pre>` with sector-trailer lines dimmed. Both dialog CSS invariants hold: no `display` on a `dialog` selector without `[open]`, and `.inspect-body` — not the dialog — scrolls.

## 7 · Icons

Extend the existing `<symbol>` sprite (outlined, 24px viewBox, 1.8 stroke) with: `i-nfc`, `i-bluetooth`, `i-link-off`, `i-check`, `i-check-circle`, `i-alert`, `i-stop`, `i-upload`, `i-restore` (history), `i-list` (log), `i-info`, `i-globe`, `i-theme`, `i-trash`, `i-copy`. The brand glyph and existing symbols stay. `markup-ids.test.ts` already fails on any `<use>` without a symbol.

## 8 · i18n

New keys (English shown; all seven catalogues): `readerConnectTitle` "Connect a reader", `readerConnectBody` "A Chameleon Ultra over Bluetooth, or this phone’s NFC (Chrome on Android, NTAG only).", `connectReaderFirst` "Connect a reader first", `sourceChooseFile` "Tap to choose a file", `sourceTapToChange` "Tap to change", `slotCard(n)` "Card n", `slotWritten` "Written", `slotWriting` "Writing", `slotWaiting` "Waiting", `slotHasData` "Has data", `cardOfTotal(i, n)` "Card i of n", `cardsNeeded(n)` "≈ n card(s) needed" (plural), `estimateAdapts` "adapts to the tapped card", `archiveAgain` "Archive another", `back` "Back", `archiveStoppedPartial(w, n)` "Stopped — w of n cards written. The archive is incomplete.", `scanStageTitle` "Tap cards in any order", `archiveRowStatus(k, n, complete)`, `fileRowMeta(size, chunks, when)`, `tagTypeLabel` "Tag type", `passwordLabel` "Password (optional)", `saveAsLabel` "Save as". Keys made obsolete (`cardEstimate`, `archiveRow`, `fileRow`) are removed from all catalogues in the same change. Russian/Ukrainian/Belarusian/Polish plurals go through `pr()`.

## 9 · Verification

- `rm -rf dist && npm test` green, including the unchanged `markup-ids`, `restore-view`, `files-view`, `i18n` suites and the new `stage-view` and Stop tests.
- `npm run build:site` succeeds (the deploy bundle).
- **Visual pass in a real browser** (Windows-host headless Chrome from WSL, 390px via an iframe wrapper because headless Chrome clamps windows to ~500px): every screen of the design table in light, dark, and Russian, at 390px and 1280px, compared side by side with its canvas draft. States to stage by script: idle connected, no reader, writing (3 cards and 24 cards), overwrite dialog open, done, scanning with two archives, files with rows and empty, log, about, inspect.
- Assertions encoded as tests where they are static: the sticky Archive button's backing is opaque (rule check), no dialog display/scroll regressions (existing), every new id present (existing).
- **Not verifiable here**: real Web Bluetooth / Web NFC writes and scans. A hardware smoke on the Chameleon (write 3 cards with one overwrite, Stop mid-write, scan them back) is required before merge and is the owner's step.

## Out of scope

- A home hub / wizard (direction A).
- Any Flutter app change, including pulling its palette further toward this one.
- Persisting the selected source mode or tab across reloads.
- Navigation rail layouts, landscape-specific layouts, and tablet breakpoints beyond the single 840px switch.

## Amendments (2026-10-05, during planning)

Found while reading the code for the implementation plan; they override the sections above.

1. **Inspect keeps preformatted text.** Identity and NFAR stay `<pre>` blocks (now inside cards), not key/value rows with a CRC chip: the same strings feed the downloadable report via `inspect-orchestrator.ts`, and re-shaping them is a logic change this redesign does not need.
2. **Reader name.** "Chameleon Ultra" is a product name and is hard-coded; only the phone reader's name is translated (new key `readerNamePhone`). `#device-status` no longer echoes the reader name (`readerChameleon` / `readerPhoneNfc` are retired) — it carries only messages such as "Reader disconnected…". The reader card's button uses a new short key `inspect` ("Inspect"); `inspectCard` stays the dialog title.
3. **Wide navigation** sits above the panels, i.e. below the reader card, because `#tabs` lives inside `<main>`. Moving it into the header would split the tablist from its panels for no gain.
4. **No separate stage supporting line.** The stage headline mirrors the orchestrator's status text (`tapCardOf` / `writingCard` / errors), which already says what to do next.
5. **Icon buttons use CSS masks.** Download, Delete, Disconnect and Close render their glyph from a `--icon` data-URI mask on `.btn-icon`, so the button's `textContent` stays exactly its translated label (the view tests assert it, and it is the accessible name). The sprite gains only the glyphs used as real `<svg>`s.
6. **Two more keys**: `overwriteTitle`, `overwriteBody` (the dialog previously had only a body sentence). **Retired keys** (removed from all seven catalogues): `cardEstimate`, `archiveRow`, `fileRow`, `readerChameleon`, `readerPhoneNfc`, `orSeparator`, `targetTag`, `password`, `saveAs`, `optionalPlaceholder`, `subTargetTag`.
7. **`ArchiveOrchestrator.run` returns its outcome** — `'done' | 'stopped' | 'failed'` — so the panel can show "Archive another" or "Back" without re-deriving it from status text. `ArchiveIO.awaitReconnect` takes the `AbortSignal`.
8. **Stop while the overwrite dialog is open is unreachable from the UI** (the dialog is modal). The orchestrator still checks `signal.aborted` after the prompt resolves, so the guarantee holds for any future caller, but the panel does not wire abort to close the dialog.
9. **Stop vs reader teardown.** The loop decides "user pressed Stop" from `signal.aborted`, never from the error type: a Web NFC teardown rejects the pending tap with its own `AbortError`, and that must still route to the reconnect path.
10. **Slot density.** Up to 5 cards, slots show glyph + "Card n" + state word; 6–10 show the glyph only (`data-dense`); above 10, the counter.
11. **Source selection is a pure function** (`app/source.ts: pickSource`) so the mode rule — a chosen file is ignored in Text mode — is unit-tested.
