import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { checkOnce, healthcheck } from '../scripts/healthcheck.js';
import { buildMarker } from '../scripts/build-marker.js';

const SHA = 'abc1234';
const HTML = '<!doctype html><html><body>ok</body></html>';
/** What build-site.ts emits as its esbuild banner. */
const stamped = (sha: string) => `/* ${buildMarker(sha)} */\nconsole.log("app");`;

/** Serve a fake deployed site; `bundle` and `jsStatus` are the knobs under test. */
async function serve(opts: { bundle: string; jsStatus?: number }): Promise<{ base: string; close: () => Promise<void> }> {
  const server: Server = createServer((req, res) => {
    if (req.url === '/app/dist/main.js') {
      const status = opts.jsStatus ?? 200;
      res.writeHead(status, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(status === 200 ? opts.bundle : 'not found');
      return;
    }
    if (req.url === '/app/' || req.url === '/app/index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(HTML);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('nope');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  return {
    base: `http://127.0.0.1:${port}/app/`,
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

test('healthy deploy: 200s, right content types, bundle carries the build marker', async () => {
  const s = await serve({ bundle: stamped(SHA) });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.deepEqual(r.failures, []);
    assert.equal(r.ok, true);
  } finally { await s.close(); }
});

test('stale edge: bundle carrying a different build marker fails', async () => {
  const s = await serve({ bundle: stamped('0000000') });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.equal(r.ok, false);
    assert.ok(r.failures.some((f) => f.includes(SHA)), `expected a marker failure, got ${JSON.stringify(r.failures)}`);
  } finally { await s.close(); }
});

test('a bare SHA occurring inside an unrelated constant is NOT a match', async () => {
  // Regression: the real bundle contains hex literals such as "C82000000000",
  // so searching for a bare 7-hex-character SHA matched by coincidence and
  // passed a stale deploy. Only the prefixed marker may satisfy the check.
  const s = await serve({ bundle: `/* ${buildMarker('0000000')} */\nl.from("C82000000000","hex");` });
  try {
    const r = await checkOnce(s.base, '0000000');
    assert.equal(r.ok, true, 'the correctly-stamped bundle must pass');

    const stale = await checkOnce(s.base, '2000000'); // appears inside C82000000000
    assert.equal(stale.ok, false, 'a SHA present only inside an unrelated constant must NOT pass');
    assert.ok(stale.failures.some((f) => f.includes('build marker')));
  } finally { await s.close(); }
});

test('missing bundle: a non-200 on main.js fails', async () => {
  const s = await serve({ bundle: '', jsStatus: 404 });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.equal(r.ok, false);
    assert.ok(r.failures.some((f) => f.includes('404')), `expected a 404 failure, got ${JSON.stringify(r.failures)}`);
  } finally { await s.close(); }
});

test('healthcheck retries a failing check and reports the last result', async () => {
  const s = await serve({ bundle: stamped('0000000') });
  const slept: number[] = [];
  try {
    const r = await healthcheck(s.base, SHA, {
      attempts: 3,
      firstDelayMs: 10,
      sleep: async (ms) => { slept.push(ms); },
    });
    assert.equal(r.ok, false);
    assert.deepEqual(slept, [10, 20], 'should back off between attempts, not after the last');
  } finally { await s.close(); }
});
