/**
 * The card-slot row of the archive write stage: one slot per card, showing
 * written / current / waiting (or warning while the overwrite prompt is open).
 *
 * Reconciles in place like restore-view.ts — slots are created or removed only
 * when `total` changes (Auto-detect re-chunks mid-write), and every label is
 * rewritten on each call so a language switch mid-write takes effect.
 */
import { t } from '../i18n/index.js';

/** Above this many cards the row would not fit a phone; a counter replaces it. */
export const MAX_SLOTS = 10;
/** Above this many cards slots show only their glyph. */
export const DENSE_ABOVE = 5;

export type SlotState = 'written' | 'current' | 'waiting' | 'warning';

export function slotState(index: number, written: number, total: number, warning: boolean): SlotState {
  if (index < written) return 'written';
  if (index === written && written < total) return warning ? 'warning' : 'current';
  return 'waiting';
}

const GLYPH: Record<SlotState, string> = {
  written: 'i-check', current: 'i-nfc', waiting: 'i-card', warning: 'i-alert',
};
/** Exported so a test can prove each id exists in index.html's sprite. The
 *  markup is built by concatenation (not a template literal) so the
 *  sprite test's static scan never reads a template expression as an icon id. */
export const SLOT_GLYPHS: readonly string[] = Object.values(GLYPH);

function stateLabel(s: SlotState): string {
  switch (s) {
    case 'written': return t.slotWritten;
    case 'current': return t.slotWriting;
    case 'waiting': return t.slotWaiting;
    case 'warning': return t.slotHasData;
  }
}

function glyphHtml(id: string): string {
  return '<svg class="ico"><use href="' + '#' + id + '"/></svg>';
}

export function renderSlots(
  container: HTMLElement,
  written: number,
  total: number,
  opts: { warning?: boolean } = {},
): void {
  const doc = container.ownerDocument;
  const kids = (): HTMLElement[] => Array.from(container.children) as HTMLElement[];

  if (total > MAX_SLOTS) {
    let counter = kids()[0];
    if (counter === undefined || counter.getAttribute('data-counter') === null) {
      for (const k of kids()) k.remove();
      counter = doc.createElement('div');
      counter.className = 'slot-counter';
      counter.setAttribute('data-counter', '');
      container.appendChild(counter);
    }
    counter.textContent = t.cardOfTotal(Math.min(written + 1, total), total);
    container.setAttribute('data-mode', 'counter');
    container.removeAttribute('data-dense');
    return;
  }

  container.setAttribute('data-mode', 'slots');
  if (total > DENSE_ABOVE) container.setAttribute('data-dense', '');
  else container.removeAttribute('data-dense');
  if (kids().some((k) => k.getAttribute('data-counter') !== null)) for (const k of kids()) k.remove();
  while (kids().length > total) kids()[kids().length - 1]!.remove();
  while (kids().length < total) {
    const slot = doc.createElement('div');
    slot.className = 'slot';
    const glyph = doc.createElement('span');
    glyph.className = 'slot-glyph';
    const name = doc.createElement('span');
    name.className = 'slot-name';
    const state = doc.createElement('span');
    state.className = 'slot-state';
    slot.append(glyph, name, state);
    container.appendChild(slot);
  }

  const warning = opts.warning === true;
  kids().forEach((slot, i) => {
    const s = slotState(i, written, total, warning);
    slot.setAttribute('data-state', s);
    const [glyph, name, state] = Array.from(slot.children) as HTMLElement[];
    if (glyph!.getAttribute('data-glyph') !== GLYPH[s]) {
      glyph!.innerHTML = glyphHtml(GLYPH[s]);
      glyph!.setAttribute('data-glyph', GLYPH[s]);
    }
    name!.textContent = t.slotCard(i + 1);
    state!.textContent = stateLabel(s);
  });
}
