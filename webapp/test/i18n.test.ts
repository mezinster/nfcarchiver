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

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LOCALE_NAMES } from '../app/i18n/dom.js';

test('every data-i18n attribute in index.html resolves to a real key', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app/index.html', import.meta.url)), 'utf8');
  const keys = [...html.matchAll(/data-i18n(?:-placeholder|-title)?="([^"]+)"/g)].map((m) => m[1]!);
  assert.ok(keys.length > 20, `expected the markup to be annotated, found ${keys.length}`);
  for (const key of keys) {
    assert.ok(key in en, `index.html references unknown message key "${key}"`);
    assert.equal(typeof en[key as keyof Messages], 'string', `"${key}" is a function; data-i18n needs a plain string`);
  }
});

test('LOCALE_NAMES covers every supported locale', () => {
  for (const l of SUPPORTED) assert.ok(LOCALE_NAMES[l], `no display name for ${l}`);
});

import { ru } from '../app/i18n/ru.js';
import { uk } from '../app/i18n/uk.js';
import { be } from '../app/i18n/be.js';
import { pl } from '../app/i18n/pl.js';
import { tr } from '../app/i18n/tr.js';
import { ka } from '../app/i18n/ka.js';

const ALL_TRANSLATIONS: Array<[string, Messages]> = [
  ['ru', ru], ['uk', uk], ['be', be], ['pl', pl], ['tr', tr], ['ka', ka],
];

test('every translation matches the English key set exactly', () => {
  const expected = Object.keys(en).sort();
  for (const [name, cat] of ALL_TRANSLATIONS) {
    assert.deepEqual(Object.keys(cat).sort(), expected, `${name} key set differs`);
  }
});

test('every translation matches English entry shapes and arity', () => {
  for (const [name, cat] of ALL_TRANSLATIONS) {
    for (const key of Object.keys(en) as Array<keyof Messages>) {
      const a = en[key], b = cat[key];
      assert.equal(typeof b, typeof a, `${name}.${String(key)} has the wrong type`);
      if (typeof a === 'function' && typeof b === 'function') {
        assert.equal(b.length, a.length, `${name}.${String(key)} has the wrong arity`);
      } else {
        assert.notEqual(b, '', `${name}.${String(key)} is empty`);
      }
    }
  }
});

test('Slavic plurals select the right form at the boundaries', () => {
  setPluralLocale('ru');
  const one = ru.clearedFiles(1), few = ru.clearedFiles(2), many = ru.clearedFiles(5);
  assert.notEqual(one, few);
  assert.notEqual(few, many);
  assert.equal(ru.clearedFiles(21), one.replace('1', '21'));
});

// Intl.PluralRules reports ['one', 'other'] for both locales, with `one` only at
// n = 1. Neither language suffixes the noun after a numeral, so the rendered noun
// must be identical for every n — the count is the only part that changes.
test('Turkish and Georgian use one noun form for every count', () => {
  for (const [name, cat] of [['tr', tr], ['ka', ka]] as Array<[string, Messages]>) {
    setPluralLocale(name);
    const one = cat.clearedFiles(1);
    for (const n of [0, 2, 5, 11, 21, 100]) {
      assert.equal(cat.clearedFiles(n), one.replace('1', String(n)), `${name} varies the noun at n=${n}`);
    }
  }
});
