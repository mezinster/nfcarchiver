import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pr, setPluralLocale } from '../app/i18n/plural.js';

test('pr selects English one/other', () => {
  setPluralLocale('en');
  const forms = { one: 'card', other: 'cards' };
  assert.equal(pr(1, forms), 'card');
  assert.equal(pr(0, forms), 'cards');
  assert.equal(pr(2, forms), 'cards');
  assert.equal(pr(11, forms), 'cards');
});

test('pr selects Russian one/few/many', () => {
  setPluralLocale('ru');
  const forms = { one: 'карта', few: 'карты', many: 'карт', other: 'карт' };
  assert.equal(pr(1, forms), 'карта');
  assert.equal(pr(2, forms), 'карты');
  assert.equal(pr(4, forms), 'карты');
  assert.equal(pr(5, forms), 'карт');
  assert.equal(pr(11, forms), 'карт');
  assert.equal(pr(21, forms), 'карта');
});

test('pr falls back to other when a category is absent', () => {
  setPluralLocale('ru');
  assert.equal(pr(2, { one: 'a', other: 'z' }), 'z');
});

import { en, type Messages } from '../app/i18n/en.js';

test('English catalogue has no empty values', () => {
  for (const [key, value] of Object.entries(en)) {
    if (typeof value === 'string') assert.notEqual(value, '', `${key} is empty`);
  }
});

test('English catalogue function entries render', () => {
  setPluralLocale('en');
  assert.equal(en.tapCardOf(1, 8), 'Tap card 1 of 8 on the reader…');
  assert.equal(en.cardEstimate(1, false), '≈ 1 card');
  assert.equal(en.cardEstimate(3, true), '≈ 3 cards (est.) — adapts to the tapped card');
  assert.equal(en.archiveDone(1), 'Done — wrote and verified 1 card.');
  assert.equal(en.clearedFiles(2), 'Cleared 2 files.');
});
