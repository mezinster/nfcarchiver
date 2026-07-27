import { MockTransport } from '../src/transport/mock-transport.js';
import { runTransportContract } from './transport-contract.js';

runTransportContract('MockTransport', () => {
  const transport = new MockTransport();
  return { transport, tap: (uid) => transport.enqueueTag(uid) };
});
