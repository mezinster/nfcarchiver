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
