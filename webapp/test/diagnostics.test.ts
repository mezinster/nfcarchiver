import { test } from 'node:test';
import assert from 'node:assert/strict';
import { diagnoseCard, type RawAntiColl } from '../app/diagnostics.js';

/** A scripted reader: returns the queued responses in order and records each call. */
function fakeReader(responses: number[][]): RawAntiColl & { calls: { data: number[]; opts: unknown }[] } {
  const calls: { data: number[]; opts: unknown }[] = [];
  let i = 0;
  return {
    calls,
    async transceive(data, opts) {
      calls.push({ data: [...data], opts });
      return new Uint8Array(responses[i++]!);
    },
  };
}

test('valid 4-byte UID: computed BCC matches the returned BCC', async () => {
  const uid = [0xaa, 0xbb, 0xcc, 0xdd];
  const bcc = 0xaa ^ 0xbb ^ 0xcc ^ 0xdd;
  const r = fakeReader([[0x04, 0x00], [...uid, bcc]]);
  const d = await diagnoseCard(r);
  assert.deepEqual([...d.atqa], [0x04, 0x00]);
  assert.deepEqual([...d.uidCl1], uid);
  assert.equal(d.bccReturned, bcc);
  assert.equal(d.bccComputed, bcc);
  assert.equal(d.bccValid, true);
  assert.equal(d.isCascade, false);
  // Correct 14443-A sequence: 7-bit WUPA (0x52), then anticollision CL1 (0x93 0x20).
  assert.deepEqual(r.calls[0]!.data, [0x52]);
  assert.deepEqual(r.calls[0]!.opts, { dataBitLength: 7, activateRfField: true, keepRfField: true });
  assert.deepEqual(r.calls[1]!.data, [0x93, 0x20]);
});

test('magic card with a wrong BCC byte is detected as invalid', async () => {
  const uid = [0x11, 0x22, 0x33, 0x44];
  const r = fakeReader([[0x04, 0x00], [...uid, 0x00]]); // BCC byte deliberately wrong
  const d = await diagnoseCard(r);
  assert.equal(d.bccReturned, 0x00);
  assert.equal(d.bccComputed, 0x11 ^ 0x22 ^ 0x33 ^ 0x44);
  assert.equal(d.bccValid, false);
});

test('7-byte UID (cascade tag 0x88) is flagged', async () => {
  const cl1 = [0x88, 0x11, 0x22, 0x33];
  const bcc = 0x88 ^ 0x11 ^ 0x22 ^ 0x33;
  const r = fakeReader([[0x44, 0x00], [...cl1, bcc]]);
  const d = await diagnoseCard(r);
  assert.equal(d.isCascade, true);
  assert.equal(d.bccValid, true); // BCC is valid over the CL1 bytes even for a cascade tag
});

test('a short anticollision response throws', async () => {
  const r = fakeReader([[0x04, 0x00], [0x11, 0x22]]);
  await assert.rejects(() => diagnoseCard(r), /expected 5/i);
});
