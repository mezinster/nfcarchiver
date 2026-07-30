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

import { pickLocale, SUPPORTED, getLocale, setLocale, onLocaleChange, t } from '../app/i18n/index.js';

test('pickLocale matches primary subtags, case-insensitively', () => {
  assert.equal(pickLocale(['ru-RU', 'en']), 'ru');
  assert.equal(pickLocale(['RU']), 'ru');
  assert.equal(pickLocale(['pl-PL']), 'pl');
  assert.equal(pickLocale(['ka']), 'ka');
});

test('pickLocale falls back to English', () => {
  assert.equal(pickLocale(['ja', 'zh-Hant']), 'en');
  assert.equal(pickLocale([]), 'en');
});

test('pickLocale prefers the earliest supported entry', () => {
  assert.equal(pickLocale(['ja', 'tr', 'ru']), 'tr');
});

test('SUPPORTED lists the seven Flutter locales', () => {
  assert.deepEqual([...SUPPORTED].sort(), ['be', 'en', 'ka', 'pl', 'ru', 'tr', 'uk']);
});

test('setLocale notifies subscribers and unsubscribe stops it', () => {
  let calls = 0;
  const off = onLocaleChange(() => { calls += 1; });
  setLocale('ru');
  assert.equal(calls, 1);
  assert.equal(getLocale(), 'ru');
  off();
  setLocale('en');
  assert.equal(calls, 1);
  assert.equal(getLocale(), 'en');
});

test('t reflects the active locale', () => {
  setLocale('en');
  assert.equal(t.tabArchive, 'Archive');
});
