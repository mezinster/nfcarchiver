# Web App — Branded Tabbed Shell + About/Licensing (Android-parity iteration 1)

**Date:** 2026-07-28
**Status:** Draft for review
**Base:** branch `webapp-branded-shell` (off `webapp-nfar-core-prototype`, PR #34)
**Predecessor:** iterations 1–3 (NFAR core, Mifare transport + UI, metadata features)

## Goal

Give the web app the **NFC Archiver identity** and a real navigational shell: a
branded, themed, tabbed UI (Archive · Restore · Files · About) that re-homes the
existing Archive and Restore features and adds an About/licensing/privacy tab.
This is the first of several Android-parity sub-projects; it is the visual
foundation the rest (localization, file manager, Web NFC) slot into.

## Non-Goals (this sub-project)

- **No framework** — stay vanilla TS + esbuild + CSS (confirmed decision). No
  React/Preact/Lit, no component library.
- **No localization yet** — strings stay inline English, concentrated so a later
  i18n sub-project can extract them. Do NOT build an i18n layer now.
- **No file persistence** — the Files tab is a placeholder; the real
  IndexedDB-backed File Manager is a later sub-project.
- **No Web NFC** — the transport stays Chameleon-only; Web NFC is a later
  sub-project.
- No change to the tested, DOM-free controllers (`controller.ts`) or the core.

## Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Stack | Vanilla TS + esbuild + CSS; no framework |
| Fidelity | Match branding (name, logo glyph, `#1976D2`, light/dark, card/button feel); adapt layout to web (tabs + responsive), not a pixel copy of Android's card-home + drill-down |
| Navigation | Tab bar: Archive · Restore · Files · About |
| About tab | Folds in the About/readme/licensing/privacy content |

## Branding reference (from the Flutter app)

- Name/title: **NFC Archiver**. Logo: the Material `nfc` glyph (recreated as an inline SVG).
- Seed color `#1976D2` (Material 3), light + dark + system.
- Feel: 16px rounded cards, full-width filled buttons (16px radius, ~56px tall),
  outlined inputs (12px radius); NFC-status banner using primary-container /
  error-container colors.
- About-dialog content: app description, supported tags, version, privacy-policy link.
- **Supported-tags text must be web-accurate:** the web app writes **Mifare
  Classic 1K via a Chameleon Ultra** (not the Android app's NTAG/Ultralight NDEF
  path). State that; note NTAG support arrives with the future Web NFC work.

## Architecture

Refactor the single imperative `app/main.ts` into a shell + per-tab panels over
the unchanged controllers. Chameleon device state moves into one module so all
panels share it.

```
webapp/app/
  version.ts            # APP_VERSION constant (also add "version" to webapp/package.json)
  main.ts               # slim entry: initialize device, shell, and panels
  ui/
    device.ts           # Chameleon state: ultra/transport, connect(), diagnose helper,
                        #   currentTransport(), onConnectionChange(cb). The ONLY app file
                        #   importing chameleon-ultra.js (with sdk-chameleon-device.ts).
    shell.ts            # app bar (logo, title, theme toggle), device bar (connect/status/
                        #   diagnose), tab bar + tab switching (show/hide, keyboard/aria)
    archive-panel.ts    # existing archive UI (file/text, compress, password, live counter,
                        #   progress) — moved out of main.ts, restyled
    restore-panel.ts    # existing scan-then-pick multi-archive restore — moved, restyled
    about-panel.ts      # description, supported tags, version, licenses, privacy summary
  controller.ts         # UNCHANGED (tested)
  estimate.ts           # UNCHANGED
  diagnostics.ts        # UNCHANGED (used by device.ts)
  index.html            # rewritten: theme <style>, app bar, device bar, tab bar, 4 panels
```

### Theme

An inline `<style>` block in `index.html` defining Material-3-style CSS custom
properties derived from `#1976D2` for **light and dark**: `--primary`,
`--on-primary`, `--primary-container`, `--on-primary-container`, `--surface`,
`--surface-variant`, `--on-surface`, `--outline`, `--error-container`,
`--on-error-container`. Default from `@media (prefers-color-scheme: dark)`, with
a manual toggle in the app bar that stamps `data-theme="light|dark"` on the root
(persisted to `localStorage`). Cards, buttons, inputs, and the status banner are
styled from these tokens to match the Flutter feel.

### Shell + tabs

`index.html` holds the static structure (app bar, device bar, four tab
`<button>`s, four `<section>` panels). `shell.ts` wires: tab switching (set
`aria-selected`, show the active `<section>`, hide the rest; arrow-key nav), the
theme toggle, and — via `device.ts` — the Connect button, connection status
text, and the Diagnose-card button. The device bar persists across tabs.

### Panels

- **Archive** and **Restore** panels contain the existing UIs, moved verbatim in
  behavior (same controllers, same flows: file/text source, counter, progress;
  scan-then-pick with per-archive rows) and restyled with the theme tokens.
  Panels read the shared transport via `device.currentTransport()` and
  enable/disable their action buttons on `device.onConnectionChange`.
- **Files** panel: a placeholder card — "No local history yet — archived files
  aren't stored in the browser in this version" — reserving the tab for the
  future File Manager.
- **About** panel: app name + version (`APP_VERSION`), description ("A
  distributed data archive system using NFC tags…"), **web-accurate supported
  tags** (Mifare Classic 1K via Chameleon Ultra), an **Open-source licenses**
  section (this app: MIT © 2026 mezinster; `chameleon-ultra.js`: MIT), and a
  **Privacy** summary (fully client-side; nothing leaves the browser; no
  tracking — consistent with `PRIVACY_POLICY.md`).

### Device state (`device.ts`)

Holds `ultra`/`transport`, the `connect()` flow (with the `await ultra.use(...)`
fix and the SDK wiring, moved from `main.ts`), the diagnose transceiver, a
`currentTransport(): ChameleonBleTransport | null`, and an
`onConnectionChange(cb: (connected: boolean) => void)` registry so panels react.
This is where `chameleon-ultra.js` is imported.

## Dependency Fence (updated)

`chameleon-ultra.js` may be imported ONLY in
`webapp/src/transport/sdk-chameleon-device.ts` and `webapp/app/ui/device.ts`
(previously `app/main.ts`; the import moves to `device.ts`). The core stays
dependency-free; no new runtime dependencies.

## Error Handling

Unchanged: the panels keep the existing `humanError` mapping (moved to a shared
spot, e.g. `device.ts` or a small `ui/errors.ts`) and typed-error handling for
archive/restore/diagnose. No new error types.

## Testing

- The controllers, estimate, diagnostics, and core keep their **85 passing
  tests unchanged** — this sub-project must not touch them, and `npm test` stays
  green (tsc over the whole project must be clean).
- The shell/panels/device are **DOM glue**, verified the same way `main.ts` is
  today: `npx tsc --noEmit` clean, `npx esbuild app/main.ts --bundle` succeeds
  (`BUNDLE OK`), and a manual visual check in the browser (tabs switch; theme
  toggle works light/dark; Archive and Restore still function end-to-end against
  a Mock/real transport; About renders).
- If any small pure helper emerges (e.g. a tab-state or theme-resolution
  function worth isolating), give it a unit test; otherwise none is required for
  glue.

## Risks

- **Refactor regressions:** splitting `main.ts` into panels could break the
  working Archive/Restore flows. Mitigation: move behavior verbatim, keep the
  controllers untouched, and verify each flow in the browser before finishing.
- **Shared device state:** panels must not each construct their own transport;
  `device.ts` is the single owner, and panels only read `currentTransport()`.
- **Theme fidelity:** hand-derived tokens won't be a pixel match to Flutter's
  generated tonal palette; "matches the branding/feel" is the bar, not identical
  hex values.
