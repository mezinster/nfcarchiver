import { MockTransport } from '../src/transport/mock-transport.js';
import { runTransportContract } from './transport-contract.js';
import { CARD_CAPACITY_BYTES, CARD_PAYLOAD_SIZE } from '../src/mifare/card-layout.js';

runTransportContract('MockTransport', () => {
  const transport = new MockTransport();
  return { transport, tap: (uid) => transport.enqueueTag(uid) };
}, { capacityBytes: CARD_CAPACITY_BYTES, maxChunkPayload: CARD_PAYLOAD_SIZE });
