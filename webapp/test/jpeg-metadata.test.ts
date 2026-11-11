import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripJpegMetadata } from '../src/photo/jpeg-metadata.js';

const ascii = (s: string) => [...s].map((c) => c.charCodeAt(0));
const seg = (marker: number, body: number[]) => [
  0xff, marker, (body.length + 2) >> 8, (body.length + 2) & 0xff, ...body,
];
const filled = (n: number, v: number) => new Array<number>(n).fill(v);
const latin1 = (b: Uint8Array) => String.fromCharCode(...b);
const u8 = (...parts: number[][]) => Uint8Array.from(parts.flat());

const soi = [0xff, 0xd8];
const app0 = seg(0xe0, [...ascii('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
const app1 = seg(0xe1, [...ascii('Exif'), 0, 0, ...ascii('GPS')]);
const com = seg(0xfe, ascii('hello'));
const dqt = seg(0xdb, filled(65, 3));
const sof = seg(0xc0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
const dht = seg(0xc4, filled(20, 1));
const sos = seg(0xda, [1, 1, 0, 0, 0x3f, 0]);
const data = [0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56];
const eoi = [0xff, 0xd9];

test('strips APP1 and COM, keeps the rest byte-identical', () => {
  const out = stripJpegMetadata(u8(soi, app0, app1, com, dqt, sof, dht, sos, data, eoi));
  assert.deepEqual(out, u8(soi, app0, dqt, sof, dht, sos, data, eoi));
  assert.equal(latin1(out).includes('Exif'), false);
});

test('JPEG without metadata is unchanged', () => {
  const input = u8(soi, app0, dqt, sof, dht, sos, data, eoi);
  assert.deepEqual(stripJpegMetadata(input), input);
});

test('PNG throws', () => {
  const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  assert.throws(() => stripJpegMetadata(png));
});

test('drops everything after the first EOI, appended gain map included', () => {
  const xmp = seg(0xe1, ascii('http://ns.adobe.com/xap/1.0/\x00GainMap'));
  const gainMap = [...soi, ...app1, ...xmp, ...dqt, ...sof, ...dht, ...sos, ...data, ...eoi];
  const out = stripJpegMetadata(u8(soi, app0, dqt, sof, dht, sos, data, eoi, gainMap, [0x00, 0x42]));
  assert.deepEqual(out, u8(soi, app0, dqt, sof, dht, sos, data, eoi));
  assert.deepEqual([...out.subarray(out.length - 2)], [0xff, 0xd9]);
  assert.equal(latin1(out).includes('Exif'), false);
  assert.equal(latin1(out).includes('GainMap'), false);
});

test('progressive layout (several scans with tables between) is kept intact', () => {
  const sof2 = seg(0xc2, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
  const dht2 = seg(0xc4, filled(18, 2));
  const data2 = [0x77, 0xff, 0x00, 0xff, 0xd3, 0x88];
  const input = u8(soi, app0, app1, dqt, sof2, dht, sos, data, dht2, sos, data2, eoi);
  assert.deepEqual(
    stripJpegMetadata(input),
    u8(soi, app0, dqt, sof2, dht, sos, data, dht2, sos, data2, eoi),
  );
});
