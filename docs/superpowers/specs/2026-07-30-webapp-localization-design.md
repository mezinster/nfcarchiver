# Webapp localization: 7 languages, matching the Android app

**Date:** 2026-07-30
**Scope:** `webapp/` only. Adds an `app/i18n/` layer, translates the browser UI
into the same seven languages the Flutter app supports, and adds a language
selector. No change to the NFAR format, the transports, the core (`src/`), the
deploy pipeline, or the Flutter app.

## Problem

The webapp ships English-only while the Flutter app has supported seven languages
since early on (`lib/l10n/app_{en,ru,tr,uk,ka,pl,be}.arb`, 138 keys each). A user
who reads the Android app in Russian gets an English browser app for the same
task, on the same data.

Localization has been on the webapp roadmap as one of the two remaining deferred
items (with Web NFC). It is a good moment to do it: the UI surface stopped moving
after the card inspector landed (PR #46), and the string surface is small and
well-bounded — roughly 45 static strings in `app/index.html`, 12 error messages
in `app/ui/errors.ts`, and about 45 status and label strings across
`app/ui/*.ts` and `app/controller.ts`. Call it ~100 keys.

Two properties of the existing code make this cheap. `humanError()` already
funnels every core error through one function, so there is exactly one place to
attach translation for anything `src/` throws. And the core is dependency-free
and never renders text, so localization has a natural home entirely inside
`app/`.

One existing habit has to go. English count strings currently dodge plurals with
`card(s)` and `file(s)` (`app/ui/archive-orchestrator.ts:40`,
`app/ui/archive-panel.ts:65`, `app/ui/files-panel.ts:54,65`,
`app/ui/restore-view.ts:11`, `app/ui/files-view.ts:16`). Russian, Ukrainian,
Polish and Belarusian each need three plural forms; the parenthetical-s trick has
no equivalent.

## Decisions (confirmed with user)

1. **Scope:** UI chrome, panel labels, dialogs, the About panel, status lines, and
   the `humanError()` messages. **Log tab entries stay English** — they are
   diagnostic output meant for bug reports, and locale-independent logs keep the
   Copy/Download feature useful across languages.
2. **Language selection:** auto-detect from `navigator.languages` with a manual
   override, persisted in `localStorage`.
3. **Relationship to the ARB files:** an independent webapp catalogue, **seeded**
   with the existing ARB translations for the ~15–20 genuinely shared terms
   (Archive, Restore, Files, About, Password, Cancel, Done, Error, …) so wording
   matches the Android app. No build-time coupling to `flutter gen-l10n`.
4. **Storage and loading:** all seven catalogues bundled as TypeScript modules.
   ~8 KB gzipped on a 176 KB bundle, no changes to `scripts/build-site.ts`, the
   build marker, the deploy sync plan, or the healthcheck.
5. **Translations authored by Claude**, seeded from the ARB as above.

## Architecture

Following the established split — the dependency-free core in `src/`, DOM and
presentation in `app/` — the entire i18n layer lives in `app/i18n/`:

```
app/i18n/
  en.ts       exports `en`, and `export type Messages = typeof en`
  ru.ts  tr.ts  uk.ts  ka.ts  pl.ts  be.ts     each `const xx: Messages = { … }`
  index.ts    supported locales, detection, active catalogue `t`, change registry,
              and the `pr()` plural helper
```

`app/i18n/` may import nothing from `src/`, and `src/` may import nothing from
`app/i18n/`. This is the same fence that keeps `chameleon-ultra.js` out of the
core, applied in the other direction: the core stays renderable-anywhere and
English-only.

### Catalogue shape

`en.ts` is the schema. Every other locale is annotated `: Messages`, so:

- a key added to `en.ts` fails the build in all six other files until translated
- a misspelled key is a compile error
- a parameterized entry's arity and parameter types are pinned across locales

That is the guarantee `flutter gen-l10n` gives the Flutter app, obtained here from
`tsc` with no codegen step.

Entries are plain strings when there is nothing to interpolate and **functions**
when there is:

```ts
// en.ts
export const en = {
  tabArchive: 'Archive',
  tapCardOf: (i: number, n: number) => `Tap card ${i} of ${n} on the reader…`,
};
export type Messages = typeof en;
```

**`en.ts` must not use `as const`.** With `as const`, `tabArchive` would have the
literal type `'Archive'` rather than `string`, and every other locale annotated
`: Messages` would be required to repeat the English literal verbatim — the
translations would not compile. Plain inference gives `string` for text entries
and the declared signature for function entries, which is exactly what is wanted.

Functions rather than format strings, because word order differs by language and
a function lets each locale rearrange its arguments freely.

### Static text in `index.html`

Translatable elements carry `data-i18n="key"`; attribute cases use
`data-i18n-placeholder` (the `#text` textarea, the `#apass` password field) and
`data-i18n-title` (the `#theme-toggle` button). `applyStaticText()` walks these on
boot and on every language change, and sets `<html lang>` to the active locale.

Deliberately **not** translated: the app name in `<h1>` and `<title>`; tech
identifiers (`NTAG213/215/216`, `Mifare Classic 1K`); the log-level option values
`debug`/`info`/`warn`/`error`. In the target-tag `<select>`, the descriptive text
translates and the chip designation does not — "Auto-detect (adapts to the card)"
is a key, `NTAG216 — 888 B` is not.

Moving all markup text into TypeScript was considered and rejected:
`app/index.html` is served before the bundle loads and is more readable and more
diffable as markup.

### Dynamic strings and the error seam

Panels and orchestrators replace string literals with `t.key` / `t.key(args)`.

`app/ui/errors.ts` is the single translation seam for the core. `humanError()`
already maps each typed error to a plain-language message; it now maps each typed
error to a catalogue key instead. `src/` is not modified, and a raw
`Error.message` remains the fallback for errors that have no mapping — a
developer-facing string, correctly left in English.

`logger.*` call sites are untouched. Log strings must not be routed through `t`.

### Plurals

Count strings become catalogue functions using `Intl.PluralRules`, which is
available in every browser that supports Web Bluetooth and in Node, so it adds no
dependency and is testable under `node --test`. The helper lives in its own
module, `app/i18n/plural.ts`, **not** in `index.ts`: the catalogues import `pr`,
and `index.ts` imports the catalogues, so putting `pr` in `index.ts` would create
a circular import. `plural.ts` owns the active locale for plural selection and
`index.ts` updates it on every language change.

```ts
// en.ts
cards: (n: number) => `${n} ${pr(n, { one: 'card', other: 'cards' })}`,
// ru.ts
cards: (n: number) => `${n} ${pr(n, { one: 'карта', few: 'карты', many: 'карт' })}`,
```

`pr()` calls `new Intl.PluralRules(activeLocale).select(n)` and looks up the
returned CLDR category, falling back to `other` when a locale does not define it.
Turkish and Georgian need only `other`; the four Slavic locales use
`one`/`few`/`many`. This also retires the `card(s)` / `file(s)` hack in English.

### Language selection and switching

Detection walks `navigator.languages` in order, comparing primary subtags
case-insensitively against the seven supported locales, and falls back to `en`. A
`<select id="lang">` in the header beside the theme toggle overrides the
detection, persisted at `localStorage['nfar-lang']` — the same convention as the
existing `nfar-theme` key.

Switching notifies a subscriber registry: `onLocaleChange(fn)`, with each panel
that renders text registering its own re-render. `applyStaticText()` is one such
subscriber.

**Accepted trade-off:** a transient status line already on screen keeps its
previous-language text until the next event rewrites it. The alternative,
`location.reload()`, is rejected because it would destroy an in-flight archive
session. Switching language touches no session state, so the selector stays
enabled at all times, including mid-archive.

## Testing

A new `test/i18n.test.ts`, run under the existing `tsc && node --test` chain. No
DOM stub is needed for any of it, consistent with how `inspect-orchestrator` is
tested behind its `InspectIO` seam.

1. **Key parity** — every locale's key set equals `en`'s, exactly. Redundant with
   `tsc` by design: the compiler catches it at build time, the test catches it if
   a future refactor loosens the type.
2. **Shape parity** — every key that is a function in `en` is a function in all
   locales, with the same `length` (arity).
3. **No empty values, and no accidentally-untranslated ones** — no catalogue may
   contain an empty string. A non-English value identical to its English source
   fails the test unless its key appears in an explicit per-locale allow-list
   (`app/i18n/same-as-english.ts`), which exists for brand and technical terms
   that are genuinely identical, e.g. `Chameleon`. The allow-list makes the
   intent reviewable instead of implicit.
4. **Locale detection** — `pickLocale(['ru-RU','en'])` → `ru`;
   `pickLocale(['ja'])` → `en`; `pickLocale(['RU'])` → `ru` (case-insensitive);
   `pickLocale([])` → `en`.
5. **Plural boundaries** — for each Slavic locale, the count strings produce the
   correct form at 1, 2, 5, 11, 21; Turkish and Georgian produce one form
   throughout.
6. **Markup/catalogue drift** — read `app/index.html` as text, extract every
   `data-i18n`, `data-i18n-placeholder` and `data-i18n-title` attribute value, and
   assert each resolves to a real key in `en`. This is the test that catches the
   most likely long-term failure, and it needs no browser.

## Non-goals

- Log tab entries (decision 1)
- Any change to `src/`, the transports, the NFAR format, or on-tag bytes
- Any change to the Flutter app or its ARB files
- RTL support — all seven locales are left-to-right
- Localized number, date, or byte-size formatting beyond plural selection
- Translating the deploy pipeline, README, or other developer-facing docs
