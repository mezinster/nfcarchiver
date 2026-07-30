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
    h.textContent = s.h;
    container.appendChild(h);
    for (const line of s.body) {
      const p = document.createElement('p');
      p.className = 'muted';
      p.textContent = line;
      container.appendChild(p);
    }
  }
}

export function initAboutPanel(): void {
  render();
  onLocaleChange(render);
}
