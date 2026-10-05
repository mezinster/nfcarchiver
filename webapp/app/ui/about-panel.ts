/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION, BUILD_SHA } from '../version.js';
import { t } from '../i18n/index.js';
import { onLocaleChange } from '../i18n/index.js';

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
}

export function initAboutPanel(): void {
  render();
  onLocaleChange(render);
}
