/** About tab: description, supported tags (web-accurate), version, licenses, privacy. */
import { APP_VERSION } from '../version.js';

const SECTIONS: Array<{ h: string; body: string[] }> = [
  { h: 'NFC Archiver', body: [
    `Web version ${APP_VERSION}`,
    'A distributed data archive system using NFC tags. Store files across multiple tags and restore them later — fully in your browser.',
  ] },
  { h: 'Supported tags', body: [
    'Mifare Classic 1K and NTAG213/215/216, via a Chameleon Ultra over Web Bluetooth.',
    '(Writing NTAG with the phone’s own NFC — no Chameleon — will come with the future Web NFC support.)',
  ] },
  { h: 'Privacy', body: [
    'Everything runs client-side. Your files, text, and passwords never leave the browser — there is no server, no upload, and no tracking.',
  ] },
  { h: 'Open-source licenses', body: [
    'NFC Archiver — MIT License © 2026 mezinster.',
    'chameleon-ultra.js — MIT License.',
  ] },
];

export function initAboutPanel(): void {
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
  for (const s of SECTIONS) {
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
