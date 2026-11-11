import { test } from 'node:test';
import assert from 'node:assert/strict';
import { candidateSides, fitToBudget, encodeManual } from '../src/photo/fit.js';
import { optimisedFileName } from '../src/photo/budget.js';
import { FakeJpegSession } from './fake-jpeg-session.js';

const model = (side: number, q: number) => Math.floor((side * side * q) / 1000);

test('candidateSides', () => {
  assert.deepEqual(candidateSides(4032), [4032, 3840, 2560, 1920, 1600, 1440, 1280, 1024, 800, 640, 480, 320]);
  assert.deepEqual(candidateSides(640), [640, 480, 320]);
  assert.deepEqual(candidateSides(200), [200]);
  assert.equal(candidateSides(1024).filter((s) => s === 1024).length, 1);
});

test('picks largest side reaching q50, then max quality', async () => {
  const budget = model(1024, 50) + 100;
  const s = new FakeJpegSession(3024, 4032, model);
  const r = await fitToBudget(s, budget);
  assert.equal(r.fits, true);
  assert.equal(r.maxSide, 1024);
  let expected = 50;
  for (let q = 50; q <= 95; q++) if (model(1024, q) <= budget) expected = q;
  assert.equal(r.quality, expected);
  assert.equal(r.bytes.length, model(1024, expected));
  assert.ok(s.calls.length <= candidateSides(4032).length + 7);
});

test('falls back to q30-49 when no side reaches q50', async () => {
  const steep = (side: number, q: number) => Math.floor((side * side * q * q * q) / 100000);
  const budget = steep(480, 35) + 10;
  const s = new FakeJpegSession(3000, 4000, steep);
  const r = await fitToBudget(s, budget);
  assert.equal(r.fits, true);
  assert.equal(r.maxSide, 480);
  let expected = 30;
  for (let q = 30; q <= 49; q++) if (steep(480, q) <= budget) expected = q;
  assert.equal(r.quality, expected);
  assert.ok(r.quality >= 30 && r.quality <= 49);
});

test('nothing fits', async () => {
  const r = await fitToBudget(new FakeJpegSession(3000, 4000, model), 10);
  assert.equal(r.fits, false);
  assert.equal(r.maxSide, 320);
  assert.equal(r.quality, 30);
});

test('budget <= 0 encodes at most once', async () => {
  for (const b of [0, -50]) {
    const s = new FakeJpegSession(3000, 4000, model);
    const r = await fitToBudget(s, b);
    assert.equal(r.fits, false);
    assert.ok(s.calls.length <= 1);
  }
});

test('small original is never upscaled', async () => {
  const s = new FakeJpegSession(200, 100, () => 5000);
  const r = await fitToBudget(s, 10);
  assert.equal(r.maxSide, 200);
  assert.ok(s.calls.every((c) => c.maxSide === 200));
});

test('deterministic', async () => {
  const a = new FakeJpegSession(3024, 4032, model);
  const b = new FakeJpegSession(3024, 4032, model);
  const ra = await fitToBudget(a, 200000);
  const rb = await fitToBudget(b, 200000);
  assert.deepEqual(a.calls, b.calls);
  assert.deepEqual([ra.maxSide, ra.quality, ra.fits], [rb.maxSide, rb.quality, rb.fits]);
});

test('encodeManual encodes once and judges fit', async () => {
  const s = new FakeJpegSession(3000, 4000, model);
  const r = await encodeManual(s, { maxSide: 800, quality: 70, budget: model(800, 70) });
  assert.equal(s.calls.length, 1);
  assert.equal(r.fits, true);
  const r2 = await encodeManual(s, { maxSide: 800, quality: 70, budget: model(800, 70) - 1 });
  assert.equal(r2.fits, false);
});

test('optimisedFileName', () => {
  const now = new Date(2026, 10, 11, 9, 5, 3);
  assert.equal(optimisedFileName('IMG_1234.HEIC', now), 'IMG_1234.jpg');
  assert.equal(optimisedFileName('a.b.png', now), 'a.b.jpg');
  assert.equal(optimisedFileName('noext', now), 'noext.jpg');
  assert.equal(optimisedFileName(undefined, now), 'photo-20261111-090503.jpg');
  assert.equal(optimisedFileName('', now), 'photo-20261111-090503.jpg');
});
