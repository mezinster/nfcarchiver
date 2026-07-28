/** App shell: tab switching and the light/dark theme toggle. DOM glue only. */

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const TABS = ['archive', 'restore', 'files', 'log', 'about'] as const;

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
