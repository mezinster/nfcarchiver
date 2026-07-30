/**
 * A marginal RF read returns fewer bytes than a full block/page-group without the
 * reader reporting an error. Such a read carries no verdict about the card: it
 * must surface as a transient CardReadError, NOT as "this card holds no NFAR
 * data" — otherwise the scan blacklists the card's UID and no re-tap can ever
 * recover it (the card silently disappears from the scan for the whole session).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ArchiveController, RestoreController } from '../app/controller.js';
import { NfarFormatError } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { NtagTransport } from '../src/transport/ntag-transport.js';
import { AutoTransport } from '../src/transport/auto-transport.js';
import { CardReadError } from '../src/transport/transport.js';
import { NtagType, ntagChunkPayloadSize } from '../src/nfc/type2.js';
import { FakeChameleon } from './fake-chameleon.js';

const MIFARE_UID = new Uint8Array([0xb9, 0x16, 0x27, 0x51]);
const NTAG_UID = new Uint8Array([0x04, 0xaa, 0xbb, 0xcc]);
const NOTE = { data: new TextEncoder().encode('Test'), fileName: 'text_note.txt', compress: true };

/** Archive the one-word note onto the presented card through the real controller. */
async function writeNote(transport: AutoTransport, payloadSize: number): Promise<void> {
  const ctrl = new ArchiveController(transport);
  assert.equal(await ctrl.prepare({ ...NOTE, payloadSize }), 1);
  assert.equal((await ctrl.writeNextCard(undefined, true)).done, true);
}

test('Mifare: a truncated block read is a transient CardReadError, not a non-NFAR verdict', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 300 });
  await transport.connect();
  device.place(MIFARE_UID);
  await writeNote(new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 300 }), CARD_PAYLOAD_SIZE);

  await transport.awaitTag();
  device.truncateNextRead();
  await assert.rejects(() => transport.readChunk(), CardReadError);

  // The card itself is fine: the very next read succeeds.
  assert.ok((await transport.readChunk()).length > 0);
});

test('NTAG: a truncated page read is a transient CardReadError, not a non-NFAR verdict', async () => {
  const device = new FakeChameleon();
  const transport = new NtagTransport(device, { pollMs: 1, defaultTimeoutMs: 300 });
  await transport.connect();
  device.placeNtag(NTAG_UID, NtagType.NTAG213);
  await writeNote(new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 300 }), ntagChunkPayloadSize(NtagType.NTAG213));

  await transport.awaitTag();
  device.truncateNextRead();
  await assert.rejects(() => transport.readChunk(), CardReadError);
  assert.ok((await transport.readChunk()).length > 0);
});

test('scan: a card misread once is still detected on a re-tap', async () => {
  const device = new FakeChameleon();
  const transport = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 300 });
  await transport.connect();
  device.place(MIFARE_UID);
  await writeNote(transport, CARD_PAYLOAD_SIZE);

  const rc = new RestoreController(transport);
  device.truncateNextRead();
  await assert.rejects(() => rc.scanNextCard(), CardReadError);
  assert.deepEqual(rc.detectedArchives(), []);

  // Re-tap: the misread must not have blacklisted the UID.
  const list = await rc.scanNextCard();
  assert.equal(list.length, 1, 'archive must be detected after a re-tap');
  assert.equal(list[0]!.complete, true);
  const out = await rc.restore(list[0]!.archiveId);
  assert.equal(out.fileName, 'text_note.txt');
  assert.equal(new TextDecoder().decode(out.data), 'Test');
});

test('scan: a genuinely blank card is still skipped once and not re-read', async () => {
  const device = new FakeChameleon();
  const transport = new AutoTransport(device, { pollMs: 1, defaultTimeoutMs: 300 });
  await transport.connect();
  device.place(MIFARE_UID); // never written — all zeros

  const rc = new RestoreController(transport);
  assert.deepEqual(await rc.scanNextCard(), []);
  // Blank verdict came from a full, healthy read, so it is trustworthy and sticky:
  // a second tap must not re-read the card.
  let reads = 0;
  const orig = device.readBlock.bind(device);
  device.readBlock = async (b, k) => { reads++; return orig(b, k); };
  assert.deepEqual(await rc.scanNextCard(), []);
  assert.equal(reads, 0, 'an already-skipped blank card must not be re-read');
});

test('a full read of a blank Mifare card still reports NfarFormatError', async () => {
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 300 });
  await transport.connect();
  device.place(MIFARE_UID);
  await transport.awaitTag();
  await assert.rejects(() => transport.readChunk(), NfarFormatError);
});
