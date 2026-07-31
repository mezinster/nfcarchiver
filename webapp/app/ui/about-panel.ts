/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION, BUILD_SHA } from '../version.js';
import { t } from '../i18n/index.js';
import { onLocaleChange } from '../i18n/index.js';

/** Built per render — reading `t` at module scope would freeze one language. */
function sections(): Array<{ h: string; body: string[] }> {
  return [
    { h: 'NFC Archiver', body: [t.aboutWebVersion(APP_VERSION, BUILD_SHA), t.aboutDescription] },
    { h: t.aboutSupportedHeading, body: [t.aboutSupportedBody, t.aboutWebNfcNote] },
    { h: t.aboutPrivacyHeading, body: [t.aboutPrivacyBody] },
    { h: t.aboutLicensesHeading, body: [t.aboutLicenseApp, t.aboutLicenseSdk] },
  ];
}

function render(): void {
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
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
