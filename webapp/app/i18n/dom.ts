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
