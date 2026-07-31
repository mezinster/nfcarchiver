# Webapp UI refactor: Android-shaped, settings-list layout

**Date:** 2026-07-31
**Scope:** `webapp/` presentation only — `app/index.html`, the view builders in `app/ui/`, and the seven i18n catalogues. No change to `src/` (the dependency-free core), to any transport, to the NFAR format, to on-tag bytes, or to the Flutter app.

## Goal

Make the web app look like a sibling of the Android app rather than a different product, borrowing the structural vocabulary of `nfcarchiver.com/resize/`: settings-list cards, tinted icon tiles, uppercase section labels, borderless surfaces separated by soft shadows, and a single prominent primary action per screen.

This is a reskin. **No feature changes, no behaviour changes, no new runtime dependencies.**

## Decisions (confirmed with user)

1. **Material 3 blue from the Flutter seed `#1976D2`**, not the reference's navy — the two apps should read as one product.
2. **Segmented control at the top** for the five sections, not a bottom navigation bar. Works on phone and desktop, keeps all five one tap away, and restructures only the tab strip.

## Decisions taken during spec writing

These were raised with the user and resolved here rather than deferred:

3. **Sub-labels are worth their translation cost, at 10 new keys — not 20.** The settings-row idiom's value comes from a row reading as a statement ("Compress — GZIP before writing") instead of a widget. Sub-labels appear only on rows where the name alone is ambiguous. Five section labels plus five sub-labels, listed exactly below.
4. **The Log and Inspect surfaces stay deliberately utilitarian.** They are instruments: dense, monospace, information-first. They inherit the new tokens (background, radius, border colour) so they do not look foreign, but they get no icon tiles, no sub-labels, and no decorative spacing. Prettifying a hex dump makes it harder to read.

## What actually creates the difference

The current stylesheet uses a single `--surface` for both the page and the cards, so cards must be outlined with `1px` borders to be visible at all. The reference splits them — page below, cards above — and drops borders entirely, letting a very soft shadow carry the separation.

That one split, plus `border-radius: 18px`, accounts for most of the perceived quality gap. Everything else in this spec is refinement layered on top of it.

## Typography: no webfont

The reference imports Inter. This spec deliberately does not, for three converging reasons:

- **Inter has no Georgian coverage.** `ka` is a shipped locale, so Georgian text would fall back to a system font mid-page — making the app *less* visually consistent, not more.
- It is an external request on every load, in a codebase with an explicit dependency fence.
- **`system-ui` resolves to Roboto on Android** — the exact font the Flutter app renders in. The system stack gets closer to the stated goal than Inter would.

Base stays `system-ui, sans-serif`. Base size moves from 15px to 14px to match the reference's density, with the type scale below.

## Design tokens

Replaces the current ad-hoc variable block. Declared for `prefers-color-scheme` **and** for the `:root[data-theme=…]` overrides the existing toggle sets, exactly as today — both mechanisms must keep working.

### Light

```
--bg               #eef1f7    page
--surface          #ffffff    cards
--primary          #0061a4
--on-primary       #ffffff
--primary-light    #d1e4ff    pills, tonal fills
--on-primary-light #001d36
--primary-icon-bg  #c5dcfa    icon tiles (a step deeper than primary-light)
--text             #1a1c1e
--text-secondary   #5b5f67
--border           #dfe2eb    hairline dividers INSIDE cards only
--error            #ba1a1a    --error-bg #ffdad6   --on-error-bg #410002
--success          #2e7d52    --success-bg #e6f4ed
--warning          #b76e00
--radius           18px       --radius-sm 12px
--shadow           0 2px 14px rgba(16,42,71,.07)
--shadow-md        0 4px 22px rgba(16,42,71,.13)
```

### Dark

```
--bg               #111417    page
--surface          #1c1f22    cards, tonally ABOVE bg
--primary          #9ecaff
--on-primary       #003258
--primary-light    #00497d
--on-primary-light #d1e4ff
--primary-icon-bg  #0d3c66
--text             #e3e2e6
--text-secondary   #a9adb5
--border           #2c3034
--error            #ffb4ab    --error-bg #93000a   --on-error-bg #ffdad6
--success          #7fd8a4    --success-bg #10331f
--warning          #f0b357
--shadow           0 2px 14px rgba(0,0,0,.35)
--shadow-md        0 4px 22px rgba(0,0,0,.5)
```

In dark mode a shadow separates almost nothing, so separation is carried by `--surface` sitting tonally *above* `--bg` — the Material 3 elevation-tint approach. The shadow tokens stay defined so the same rules apply in both themes without branching.

### Type scale

```
section label   12px / 600 / uppercase / letter-spacing .09em / --text-secondary
row name        14px / 500 / --text
row sub         12px / 400 / --text-secondary
primary button  16px / 600
body            14px / 1.5
monospace       13px  (device status, log, inspect dumps)
```

### Layout

Main column `max-width: 36rem` (576px). The reference uses 520px, today's app uses 640px; 576px keeps the phone-shaped proportions while leaving the Log panel's monospace output readable. The Inspect dialog keeps its existing wider `min(96vw, 62rem)` — a hex dump has different needs from a settings list.

## Component vocabulary

A small closed set, reused across every panel. This is what makes the result feel designed rather than merely restyled.

| Class | Definition |
|---|---|
| `.section-label` | Uppercase label above a card. Type scale as above; padding `2px 4px 0`. |
| `.card` | `background: var(--surface)`, `border-radius: var(--radius)`, `box-shadow: var(--shadow)`, `overflow: hidden`, **no border**. Rows own their own padding; the card has none. |
| `.row` | Settings row: `display:flex`, `align-items:center`, `gap:14px`, `padding:15px 18px`, `border-bottom:1px solid var(--border)`, none on `:last-child`. |
| `.icon-tile` | `38×38`, `border-radius:11px`, `background: var(--primary-icon-bg)`, centred inline SVG at `18×18`, `stroke: var(--primary)`, `stroke-width:1.8`, `fill:none`, round caps and joins. |
| `.row-text` | `flex:1; min-width:0` wrapper for `.row-name` + optional `.row-sub`. |
| `.row-control` | `flex-shrink:0`, holds the input/select/switch. |
| `.switch` | `44×24` track wrapping a visually-hidden `<input type="checkbox">`; `18px` knob, `transform: translateX(20px)` when checked, `.2s` transition. |
| `.seg` | Segmented control: flex track on `--bg`, `border-radius:10px`, `padding:3px`; `.seg-btn` transparent, `.seg-btn[aria-selected="true"]` gets `background: var(--surface)`, `color: var(--primary)`, small shadow. |
| `.status-pill` | `border-radius:50px`, `background: var(--primary-light)`, `padding:11px 18px`, leading `24px` circular dot whose colour reflects connection state. |
| `.btn-primary` | Full width, `padding:17px`, `border-radius: var(--radius)`, `background: var(--primary)`, `--shadow-md`, `translateY(-1px)` on hover, `:disabled { opacity:.45; box-shadow:none; transform:none }`. |
| `.btn-tonal` | Secondary action: `background: var(--primary-light)`, `color: var(--primary)`, `border-radius: var(--radius-sm)`, no shadow. |
| `.btn-text` | Tertiary: transparent, `--text-secondary`, colours to `--text` on hover. Used for Clear/Copy/Download in the Log panel. |

All controls keep their native elements. `.switch` wraps the existing `<input type="checkbox">` rather than replacing it, so `archive-panel.ts` keeps reading `$('compress').checked` unchanged, and keyboard focus, form semantics and screen-reader behaviour come for free. A `<div>`-based toggle would need `role="switch"`, `aria-checked` and key handlers to reach parity with what the checkbox already provides.

`<progress id="archive-bar">` is **kept and styled** via `::-webkit-progress-bar` / `::-webkit-progress-value` / `::-moz-progress-bar`, rather than replaced with divs. `archive-panel.ts` toggles indeterminate state by removing the `value` attribute; a div-based bar would require reimplementing that in TS for no visual gain.

## Panel-by-panel structure

### Header

Centred title, `17px/600`. Language `<select>` and theme toggle become `30px` circular icon buttons on the right, matching the reference's `.header-info-btn`. The header loses its solid primary background and sits on `--bg`; the app no longer needs a coloured bar to look finished.

### Device bar

Becomes a `.status-pill` showing `#conn` with a state-coloured dot (`--success` connected, `--text-secondary` disconnected), followed by Connect / Use phone NFC / Inspect / Disconnect as `.btn-tonal`. `#device-status` stays a monospace `<pre>`, muted, below the pill.

`#conn` must remain free of any `data-i18n` attribute — `device.ts` owns its text and `applyStaticText()` would overwrite live connection state with the disconnected string. Asserted by `test/i18n.test.ts`.

### Tabs

The existing `#tabs` strip becomes `.seg`. **`#tabs` itself takes the class — it is not wrapped in a new element and not renamed.** `shell.ts` binds and updates through `document.querySelector('#tabs button[data-tab="…"]')` and sets `aria-selected` on the result, so `#tabs` must remain the buttons' ancestor and each button must keep its `data-tab` value. `role="tab"` and `aria-selected` also stay: `activateTab()` writes the latter and the `.seg-btn[aria-selected="true"]` rule is what renders the active pill, so the selected state needs no new class.

The five `data-tab` values (`archive`, `restore`, `files`, `log`, `about`) and the matching `panel-<name>` panel IDs are fixed by the `TABS` tuple in `shell.ts`.

With five items and long labels in RU and KA, the track must not overflow the viewport: `.seg` gets `overflow-x: auto`, `scrollbar-width: none`, `-webkit-overflow-scrolling: touch`, and hides the WebKit scrollbar. `shell.ts` gains one line to call `scrollIntoView({ block: 'nearest', inline: 'nearest' })` on the newly selected tab so an off-screen selection is always brought into view.

### Archive panel

```
SOURCE
  ┌ row  file icon    Choose file            [file input] ┐
  └ row  pencil icon  Or type text…          [textarea]   ┘   (textarea spans full row width below its label)

SETTINGS
  ┌ row  card icon    Target tag             [select]     ┐
  │ row  archive icon Compress               [switch]     │
  └ row  lock icon    Password               [password]   ┘

  ≈ N cards                                       (.cardcount, right-aligned, --text-secondary)

  [ Archive to cards ]                            (.btn-primary)

  progress card (hidden until writing)
  status                                          (.status)
```

The `<textarea>` does not fit the fixed-height row idiom. Its row uses `flex-direction: column; align-items: stretch` so the label sits above a full-width textarea — a documented, deliberate exception to `.row`.

### Restore panel

```
  [ Scan cards ]                                  (.btn-primary)
  [ Stop ]                                        (.btn-tonal, full width)

DETECTED ARCHIVES
  ┌ card containing #archives rows ┐

OUTPUT
  └ row  save icon    Save as                [text input] ┘

  status
```

`#archives` rows are built by `restore-view.ts`, which reconciles in place and must keep doing so — a rebuilt row would drop the click listener mid-scan. Its row markup upgrades from `.arch` (span + button) to the `.row` shape: `.row-text` holding the archive description, `.row-control` holding a `.btn-tonal` Restore button. The `data-archive-id` attribute and reconciliation logic are unchanged.

### Files panel

`files-view.ts` renders each entry as a `.row`: icon tile, its existing composed label, and Download/Delete controls in `.row-control`. `#files-empty`, `#files-info`, `#files-status` and `#files-clear` keep their IDs; Clear all becomes `.btn-text`.

**List rows carry no sub-label.** `t.fileRow` and `t.archiveRow` each compose name, size, date, encryption state and a pluralised chunk count into one string. Splitting them into a name and a meta line would mean replacing two keys and reworking their plural logic across seven locales, for a marginal visual gain — so both list rows keep their single composed label in `.row-name`. Sub-labels remain a feature of the fixed settings rows, where the strings are new anyway.

### Log panel

Controls move into one `.card` with a `.row` of `.btn-text` actions; level stays a `<select>`, auto-scroll and mirror-to-console become `.switch` rows. `#log` itself is untouched apart from inheriting `--surface`, `--radius-sm` and the monospace scale. No icon tiles.

### About panel

`about-panel.ts` renders into `#about-content`. It gains `.section-label` headings and `.card` wrappers, no other change.

### Dialogs

`#overwrite-dialog` gets `--radius`, `--shadow-md` and the new button classes. `#inspect-dialog` keeps its wider max-width and monospace dumps, inheriting only the surface and radius tokens.

## New i18n keys

Ten keys, added to `app/i18n/en.ts` (the schema) and all six translation catalogues. `tsc` fails until every catalogue has them, which is the enforcement mechanism.

**Section labels**

| Key | English |
|---|---|
| `sectionSource` | Source |
| `sectionSettings` | Settings |
| `sectionArchives` | Detected archives |
| `sectionRestoredFiles` | Restored files |
| `sectionLogOptions` | Log options |

**Row sub-labels**

| Key | English |
|---|---|
| `subChooseFile` | Any file, split across cards |
| `subTypeText` | Saved as text_note.txt |
| `subTargetTag` | Card type and capacity |
| `subCompress` | GZIP before writing |
| `subPassword` | AES-256-GCM, optional |

Existing keys are reused wherever the label is unchanged (`compress`, `password`, `targetTag`, `orText`, `saveAs`, `clearAll`, `logLevel`, `autoScroll`, `mirrorToConsole`). No existing key is renamed or removed.

## Icons

Inline SVG only — the dependency fence forbids an icon package, and inline paths avoid a second network request. A single `<svg>` sprite block at the top of `<body>`, hidden, with `<symbol>` definitions referenced by `<use>`. Eight icons: file, pencil, card, archive, lock, save, folder, download. Stroke-based to match the reference: `fill:none`, `stroke-width:1.8`, round caps and joins, inheriting `stroke: var(--primary)` from `.icon-tile`.

## Hard constraints

1. **Every element ID survives verbatim.** Eight modules resolve elements through `getElementById`, and `shell.ts` additionally uses a `#tabs button[data-tab]` query; a renamed ID or attribute returns null and fails silently at runtime, and no test would catch it.
2. `#tabs` keeps its ID and stays the buttons' ancestor; `data-tab`, `role="tab"` and `aria-selected` on those buttons are load-bearing for `shell.ts`. `#theme-toggle`, `#lang` and every `panel-<name>` are likewise fixed.
3. `#conn` carries no `data-i18n`.
4. Every `data-i18n`, `data-i18n-placeholder` and `data-i18n-title` attribute must resolve to a plain-string key in `en.ts`.
5. Dark mode keeps working through both `prefers-color-scheme` and `:root[data-theme=…]`.
6. No runtime dependency added; nothing imported into `src/`.
7. `npm run build:site` must still stamp and pass its healthcheck.

## Testing

A reskin is largely not unit-testable, and this spec does not pretend otherwise.

**Automated, must stay green:**
- `test/i18n.test.ts` — every `data-i18n` key in the restructured HTML resolves; `#conn` remains untranslated; no empty catalogue values.
- `test/files-view.test.ts` and `test/restore-view.test.ts` — updated to assert the new `.row` structure. Both currently assert on rendered output, so they change with it. The reconciliation guarantees they cover (stable rows, surviving listeners) must keep being asserted.
- The full suite — 289 tests — proving no behaviour regressed.

**Manual, and stated as manual:**
`npm run app` on `localhost:8000`, verified in light and dark, at 360px and desktop widths, with `ru` selected (longest strings) and `ka` selected (tallest glyphs), confirming: the tab strip scrolls rather than overflowing, no button text clips, and the archive flow renders progress and status correctly.

## Non-goals

- Any behaviour, feature, or wording change beyond the ten new keys
- Restyling the Inspect hex dump or the Log stream beyond token inheritance
- A bottom navigation bar (explicitly rejected)
- A webfont (explicitly rejected)
- Touching the Flutter app's theme
- Making `device.ts` testable under `node --test` — still blocked on `BluetoothUUID` at module scope, still out of scope

## Risks

- **Silent breakage via renamed IDs or attributes.** The mitigation is constraint 1 plus a full manual pass; there is no automated net for `getElementById` returning null.
- **Translation quality.** Turkish and Georgian have never had a native review, and this adds ten more strings to that debt. Recorded, not resolved here.
- **Row idiom versus wide inputs.** The textarea and the password field do not naturally fit a fixed-height row; the textarea's column exception is specified above, and the password input is width-capped in `.row-control`.
