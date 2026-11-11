/**
 * What a tapped tag's SAK byte says it is. Mirror of lib/core/mifare/sak.dart.
 * Anything unrecognised (Mifare Mini 0x09, Classic 2K 0x19, ...) is
 * 'unsupported': the layout only knows 1K and 4K geometry.
 */

import type { CardSize } from './card-layout.js';

export type TagKind = 'classic1k' | 'classic4k' | 'ntag' | 'unsupported';

export function classifySak(sak: number): TagKind {
  switch (sak) {
    case 0x08:
      return 'classic1k';
    case 0x18:
    case 0x38:
    case 0x98:
      return 'classic4k';
    case 0x00:
      return 'ntag';
    default:
      return 'unsupported';
  }
}

/** Card geometry for a Classic kind; null for non-Classic kinds. */
export function cardSizeFor(kind: TagKind): CardSize | null {
  switch (kind) {
    case 'classic1k':
      return '1k';
    case 'classic4k':
      return '4k';
    default:
      return null;
  }
}
