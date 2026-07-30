import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInspection, type InspectIO } from '../app/ui/inspect-orchestrator.js';
import type { RawAntiColl } from '../app/diagnostics.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';
import { chunkToBlocks } from '../src/mifare/card-layout.js';
import { encodeNdefMime } from '../src/nfc/ndef.js';
import { wrapType2Tlv, NtagType } from '../src/nfc/type2.js';
import { FACTORY_KEY_A } from '../src/transport/chameleon-device.js';
import { FakeChameleon } from './fake-chameleon.js';

const UID = new Uint8Array([0xb9, 0x16, 0x27, 0x51]);

/** Records everything the orchestrator pushed, in order. */
function stubIo() {
  const calls: string[] = [];
  const rows: string[] = [];
  const io: InspectIO = {
    setIdentity: (t) => { calls.push('identity'); void t; },
    setNfar: (t) => { calls.push(`nfar:${t.split('\n')[0]}`); },
    appendRow: (line) => { calls.push('row'); rows.push(line); },
    setProgress: (t) => { calls.push(`progress:${t}`); },
    setReport: () => { calls.push('report'); },
    setStatus: (t) => { calls.push(`status:${t}`); },
  };
  return { io, calls, rows };
}

/** Put a real NFAR chunk on a fake Classic card. */
async function writeChunk(device: FakeChameleon): Promise<void> {
  const payload = new TextEncoder().encode('Test');
  const bytes = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  for (const { block, data } of chunkToBlocks(bytes)) {
    await device.writeBlock(block, FACTORY_KEY_A, data);
  }
}

/** Hand-assembled NDEF MIME record with a foreign type, mirroring the layout
 *  `encodeNdefMime` produces but for a MIME type that is not ours. Used to
 *  prove that a well-formed NDEF record with the wrong MIME type is reported
 *  as "valid NDEF, not NFAR" rather than "0 bytes read". */
function encodeForeignNdefMime(payload: Uint8Array): Uint8Array {
  const type = new TextEncoder().encode('text/plain');
  const short = payload.length < 256;
  const flags = 0x80 | 0x40 | 0x02 | (short ? 0x10 : 0); // MB | ME | TNF(media) | SR?
  const lenBytes = short ? 1 : 4;
  const out = new Uint8Array(2 + lenBytes + type.length + payload.length);
  let i = 0;
  out[i++] = flags;
  out[i++] = type.length;
  if (short) {
    out[i++] = payload.length;
  } else {
    out[i++] = (payload.length >>> 24) & 0xff;
    out[i++] = (payload.length >>> 16) & 0xff;
    out[i++] = (payload.length >>> 8) & 0xff;
    out[i++] = payload.length & 0xff;
  }
  out.set(type, i); i += type.length;
  out.set(payload, i);
  return out;
}

/** Write a padded Type-2 TLV to an NTAG's NDEF area starting at page 4. */
async function writeNtagTlv(device: FakeChameleon, tlv: Uint8Array): Promise<void> {
  const padded = new Uint8Array(Math.ceil(tlv.length / 4) * 4);
  padded.set(tlv);
  for (let pg = 0; pg < padded.length / 4; pg++) {
    await device.transceive14a(new Uint8Array([0xa2, 4 + pg, ...padded.subarray(pg * 4, pg * 4 + 4)]));
  }
}

const okRaw: RawAntiColl = {
  async transceive(data) {
    // 7-bit WUPA -> ATQA; anticollision CL1 -> UID + BCC.
    if (data[0] === 0x52) return new Uint8Array([0x04, 0x00]);
    return new Uint8Array([0xb9, 0x16, 0x27, 0x51, 0xd9]);
  },
};

test('identity and the NFAR panel appear before the dump finishes', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  await writeChunk(device);
  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const identityAt = calls.indexOf('identity');
  const nfarAt = calls.findIndex((c) => c.startsWith('nfar:'));
  const lastRowAt = calls.lastIndexOf('row');
  assert.ok(identityAt >= 0 && identityAt < lastRowAt, 'identity must precede the last row');
  assert.ok(nfarAt >= 0 && nfarAt < lastRowAt, 'the NFAR panel must precede the last row');
});

test('rows arrive progressively, one per unit, with progress reported', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const { io, calls, rows } = stubIo();
  await runInspection(device, okRaw, io);

  assert.equal(rows.length, 64);
  assert.ok(calls.some((c) => c === 'progress:reading… 1/64'));
  assert.ok(calls.some((c) => c === 'progress:64/64 read'));
  assert.ok(calls.includes('report'), 'the report must be assembled at the end');
});

test('a real chunk on the card is decoded, CRC verified', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  await writeChunk(device);
  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /NFAR/);
  assert.ok(!/not NFAR/.test(nfar), nfar);
});

test('a blank card reports not-NFAR and still dumps', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const { io, calls, rows } = stubIo();
  await runInspection(device, okRaw, io);

  assert.ok(calls.some((c) => /not NFAR/.test(c)));
  assert.equal(rows.length, 64, 'the raw dump is unaffected by the card not being NFAR');
});

test('a failed anticollision does not stop the dump', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const badRaw: RawAntiColl = { async transceive() { throw new Error('no response'); } };
  const { io, calls, rows } = stubIo();
  await runInspection(device, badRaw, io);

  assert.ok(calls.some((c) => c === 'identity'), 'identity is still rendered');
  assert.equal(rows.length, 64, 'readBlock does its own select, so the dump proceeds');
});

test('an NTAG chunk is unwrapped from its NDEF envelope before describing', async () => {
  // NTAG stores the chunk inside a Type-2 TLV around an NDEF MIME record.
  // Concatenating raw pages would show the TLV header, not NFAR magic, so
  // without the unwrap this panel would report "not NFAR" for a perfectly
  // good NTAG archive card.
  const device = new FakeChameleon();
  device.placeNtag(new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]), NtagType.NTAG213);
  const payload = new TextEncoder().encode('Test');
  const chunk = encodeChunk({
    archiveId: new Uint8Array(16).fill(0xab), totalChunks: 1, chunkIndex: 0,
    payload, crc32: crc32(payload), flags: 0,
  });
  const tlv = wrapType2Tlv(encodeNdefMime(chunk));
  const padded = new Uint8Array(Math.ceil(tlv.length / 4) * 4);
  padded.set(tlv);
  for (let pg = 0; pg < padded.length / 4; pg++) {
    await device.transceive14a(new Uint8Array([0xa2, 4 + pg, ...padded.subarray(pg * 4, pg * 4 + 4)]));
  }

  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /NFAR/, `expected the NDEF envelope to be unwrapped, got: ${nfar}`);
  assert.ok(!/not NFAR/.test(nfar), nfar);
});

test('a blank NTAG reports no complete NDEF TLV, not a false "0 bytes read"', async () => {
  // No TLV at all is a different fact from "envelope still arriving mid-dump",
  // and it must not be reported the way describeNfar reports a genuinely short
  // buffer ("only 0 bytes read; need at least N") — that would claim nothing
  // was read when the whole card was read.
  const device = new FakeChameleon();
  device.placeNtag(new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]), NtagType.NTAG213);

  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /no complete NDEF TLV/, nfar);
  assert.ok(!/0 bytes read/.test(nfar), nfar);
});

test('a foreign NDEF MIME type is reported as valid NDEF, not NFAR — not "0 bytes read"', async () => {
  // The TLV and NDEF record are both well-formed here; only the MIME type is
  // wrong. That is a permanent, different fact from an envelope that has not
  // finished arriving, and must be told apart from it.
  const device = new FakeChameleon();
  device.placeNtag(new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]), NtagType.NTAG213);
  const foreign = encodeForeignNdefMime(new TextEncoder().encode('hello'));
  await writeNtagTlv(device, wrapType2Tlv(foreign));

  const { io, calls } = stubIo();
  await runInspection(device, okRaw, io);

  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /valid NDEF record, but not an NFAR chunk/, nfar);
  assert.ok(!/0 bytes read/.test(nfar), nfar);
});

test('Mifare Classic with a non-factory key reports unreadable blocks, not "0 bytes read"', async () => {
  // Sector 0 keyed off-factory means the manufacturer/data blocks that would
  // hold the chunk all come back auth-failed, so the reconstructed byte
  // stream is empty. describeNfar would call that "0 bytes read", which is
  // false — the dump did read 64 blocks, all 60 usable ones came back marked
  // "auth failed", and the panel should say so instead of implying nothing
  // was read at all.
  const device = new FakeChameleon();
  device.defineCard(UID, { keyA: new Uint8Array([1, 2, 3, 4, 5, 6]) });
  device.place(UID);
  const { io, calls, rows } = stubIo();
  await runInspection(device, okRaw, io);

  assert.equal(rows.length, 64, 'the raw dump still runs to completion');
  const nfar = calls.filter((c) => c.startsWith('nfar:')).pop()!;
  assert.match(nfar, /blocks holding the chunk could not be read/, nfar);
  assert.ok(!/0 bytes read/.test(nfar), nfar);
});

test('an aborted inspection reports it and stops early', async () => {
  const device = new FakeChameleon();
  device.place(UID);
  const ac = new AbortController();
  const rows: string[] = [];
  const { io, calls } = stubIo();
  const io2: InspectIO = { ...io, appendRow: (l) => { rows.push(l); if (rows.length === 4) ac.abort(); } };
  await runInspection(device, okRaw, io2, ac.signal);

  assert.ok(rows.length < 64, `expected an early stop, got ${rows.length}`);
  assert.ok(calls.includes('status:Stopped.'), 'the Stopped status must be reported');
  assert.ok(calls.includes('report'), 'the report must still be assembled on abort');
});
