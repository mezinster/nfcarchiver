/** App shell: tab switching, the light/dark theme toggle, and the language
 *  selector. DOM glue only. */
import { SUPPORTED, getLocale, storeLocale, onLocaleChange, type Locale } from '../i18n/index.js';
import { applyStaticText, LOCALE_NAMES } from '../i18n/dom.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const TABS = ['archive', 'restore', 'files', 'log', 'about'] as const;

function activateTab(name: string): void {
  for (const t of TABS) {
    const btn = document.querySelector<HTMLButtonElement>(`#tabs button[data-tab="${t}"]`)!;
    const panel = $(`panel-${t}`);
    const selected = t === name;
    btn.setAttribute('aria-selected', String(selected));
    // The strip scrolls horizontally (five labels do not fit a 360px viewport
    // in RU or KA), so a selection landing off-screen must be brought into view.
    if (selected) btn.scrollIntoView({ block: 'nearest', inline: 'nearest' });
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

export function initShell(): void {
  for (const t of TABS) {
    document.querySelector<HTMLButtonElement>(`#tabs button[data-tab="${t}"]`)!
      .addEventListener('click', () => activateTab(t));
  }
  initTheme();
  initLanguage();
}
