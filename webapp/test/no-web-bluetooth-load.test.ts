import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

/**
 * `chameleon-ultra.js/plugin/WebbleAdapter` calls `BluetoothUUID.canonicalUUID`
 * at module scope. In a browser without Web Bluetooth — every iOS browser,
 * Chrome included, since they are all WebKit — a static import throws a
 * ReferenceError while the bundle evaluates, before main.ts wires a single
 * handler: the whole page renders but no button works.
 *
 * Node has no `BluetoothUUID` either, so evaluating the bundled device bar here
 * reproduces exactly that failure. The adapter must stay behind a dynamic
 * import, evaluated only when the user asks to connect a Chameleon.
 */
test('device bar bundle evaluates without Web Bluetooth (iOS WebKit)', async () => {
  assert.equal(typeof (globalThis as { BluetoothUUID?: unknown }).BluetoothUUID, 'undefined');
  const dir = mkdtempSync(join(tmpdir(), 'nfar-noble-'));
  try {
    const outfile = join(dir, 'device.mjs');
    await build({
      entryPoints: [fileURLToPath(new URL('../../app/ui/device.ts', import.meta.url))],
      bundle: true,
      format: 'esm',
      outfile,
      logLevel: 'silent',
    });
    await assert.doesNotReject(import(pathToFileURL(outfile).href));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
