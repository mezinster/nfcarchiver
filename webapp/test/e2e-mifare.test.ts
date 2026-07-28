import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archive, restore } from '../src/pipeline.js';
import { encodeChunk, decodeChunk, FLAG_COMPRESSED, FLAG_ENCRYPTED, type Chunk } from '../src/chunk.js';
import { CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';
import { ChameleonBleTransport } from '../src/transport/chameleon-ble.js';
import { FakeChameleon } from './fake-chameleon.js';

function compressiblePayload(): Uint8Array {
  const words: string[] = [];
  for (let i = 0; i < 400; i++) words.push(`nfar-card-${i}-payload`);
  return new TextEncoder().encode(words.join(' '));
}

test('archive -> write to fake cards -> shuffled+duplicate scan -> restore', async () => {
  const original = compressiblePayload();
  const device = new FakeChameleon();
  const transport = new ChameleonBleTransport(device, { pollMs: 1, defaultTimeoutMs: 500 });
  await transport.connect();

  const chunks = await archive(original, { payloadSize: CARD_PAYLOAD_SIZE, compress: true, password: 'e2e' });
  assert.ok(chunks.length >= 2, `expected multiple cards, got ${chunks.length}`);
  assert.ok(chunks.every((c) => c.flags === (FLAG_COMPRESSED | FLAG_ENCRYPTED)));

  // Write each chunk to its own uniquely-identified card.
  const uids = chunks.map((_, i) => new Uint8Array([0xc0, 0xde, 0x00, i]));
  for (let i = 0; i < chunks.length; i++) {
    device.place(uids[i]!);
    await transport.awaitTag();
    await transport.writeChunk(encodeChunk(chunks[i]!));
  }

  // Restore: scan cards in reverse order, with one accidental re-tap that must be ignored.
  const collected = new Map<number, Chunk>();
  const scanOrder = [...uids].reverse();
  scanOrder.splice(1, 0, scanOrder[0]!); // duplicate the first scanned card
  for (const uid of scanOrder) {
    device.place(uid);
    const tag = await transport.awaitTag();
    const chunk = decodeChunk(await transport.readChunk());
    if (!collected.has(chunk.chunkIndex)) collected.set(chunk.chunkIndex, chunk);
    // UID identity: a repeat scan of an already-collected card is a no-op above
    void tag;
  }

  const restored = await restore([...collected.values()], 'e2e');
  assert.deepEqual(restored, original);
});
