/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION, BUILD_SHA } from '../version.js';
import { t } from '../i18n/index.js';
import { onLocaleChange } from '../i18n/index.js';
import { isDevUnlocked, unlockDev, isMifare4kEnabled, setMifare4kEnabled } from '../dev-flags.js';

const TAPS_TO_UNLOCK = 7;
const TAP_IDLE_MS = 2000;
let taps = 0;
let tapTimer: ReturnType<typeof setTimeout> | undefined;

function onVersionTap(): void {
  if (isDevUnlocked()) return;
  clearTimeout(tapTimer);
  if (++taps >= TAPS_TO_UNLOCK) {
    taps = 0;
    unlockDev();
    render();
    return;
  }
  tapTimer = setTimeout(() => { taps = 0; }, TAP_IDLE_MS);
}

function devSection(): HTMLElement {
  const wrap = document.createElement('div');
  const h = document.createElement('h3');
  h.className = 'section-label';
  h.textContent = t.devOptions;
  const card = document.createElement('div');
  card.className = 'card about-card';
  const note = document.createElement('p');
  note.textContent = t.devUnlocked;
  const label = document.createElement('label');
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.id = 'dev-mifare4k';
  box.checked = isMifare4kEnabled();
  box.addEventListener('change', () => setMifare4kEnabled(box.checked));
  label.append(box, ' ', t.mifare4kToggle);
  const hint = document.createElement('p');
  hint.textContent = t.mifare4kHint;
  card.append(note, label, hint);
  wrap.append(h, card);
  return wrap;
}

/** Built per render — reading `t` at module scope would freeze one language. */
function sections(): Array<{ h: string; body: string[] }> {
  return [
    { h: t.aboutSupportedHeading, body: [t.aboutSupportedBody, t.aboutWebNfcNote] },
    { h: t.aboutPrivacyHeading, body: [t.aboutPrivacyBody] },
    { h: t.aboutLicensesHeading, body: [t.aboutLicenseApp, t.aboutLicenseSdk] },
  ];
}

function render(): void {
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
  // Header block (draft 7): logo tile, name, version, one-line description.
  const head = document.createElement('div');
  head.className = 'about-head';
  head.innerHTML = '<span class="icon-tile about-logo"><svg class="brand-ico" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-brand"/></svg></span>';
  const name = document.createElement('h2');
  name.textContent = 'NFC Archiver';
  const version = document.createElement('p');
  version.textContent = t.aboutWebVersion(APP_VERSION, BUILD_SHA);
  version.addEventListener('click', onVersionTap);
  const description = document.createElement('p');
  description.textContent = t.aboutDescription;
  head.append(name, version, description);
  container.appendChild(head);
  for (const s of sections()) {
    const h = document.createElement('h3');
    h.className = 'section-label';
    h.textContent = s.h;
    container.appendChild(h);
    // One card per section, not per paragraph: a section's body lines belong
    // together, and carding each <p> separately would fragment them.
    const card = document.createElement('div');
    card.className = 'card about-card';
    for (const line of s.body) {
      const p = document.createElement('p');
      p.textContent = line;
      card.appendChild(p);
    }
    container.appendChild(card);
  }
  if (isDevUnlocked()) container.appendChild(devSection());
}

export function initAboutPanel(): void {
  render();
  onLocaleChange(render);
}
