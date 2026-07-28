/**
 * Owns the Chameleon Ultra device/transport for the whole app — the single
 * place `chameleon-ultra.js` is imported on the app side. Panels read the
 * shared transport via currentTransport() and react to onConnectionChange().
 */

import { ChameleonUltra, Buffer } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../../src/transport/sdk-chameleon-device.js';
import { AutoTransport } from '../../src/transport/auto-transport.js';
import { diagnoseCard, type RawAntiColl } from '../diagnostics.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0').toUpperCase()).join(' ');

let ultra: ChameleonUltra | null = null;
let transport: AutoTransport | null = null;
const listeners: Array<(connected: boolean) => void> = [];

export function currentTransport(): AutoTransport | null {
  return transport;
}

export function onConnectionChange(cb: (connected: boolean) => void): void {
  listeners.push(cb);
}

export function initDeviceBar(): void {
  const deviceStatus = $('device-status');

  $('connect').addEventListener('click', async () => {
    log.info('device', 'Connecting');
    try {
      ultra = new ChameleonUltra();
      // use() is async (the adapter's install() runs availability checks etc.);
      // it MUST be awaited before connect(), or this.port is still undefined.
      await ultra.use(new WebbleAdapter());
      transport = new AutoTransport(new SdkChameleonDevice(ultra));
      await transport.connect();
      $('conn').textContent = 'connected';
      ($('diagnose') as HTMLButtonElement).disabled = false;
      for (const cb of listeners) cb(true);
      deviceStatus.textContent = 'Connected.';
      log.info('device', 'Connected');
    } catch (e) {
      deviceStatus.textContent = humanError(e);
      log.error('device', 'Connect failed', { error: String(e) });
    }
  });

  $('diagnose').addEventListener('click', async () => {
    if (!ultra) return;
    const dev = ultra;
    const raw: RawAntiColl = {
      async transceive(data, opts) {
        const resp = await dev.cmdHf14aRaw({
          data: Buffer.from(data),
          dataBitLength: opts?.dataBitLength ?? 0,
          activateRfField: opts?.activateRfField ?? false,
          keepRfField: opts?.keepRfField ?? false,
          checkResponseCrc: false,
          waitResponse: true,
        });
        return new Uint8Array(resp);
      },
    };
    deviceStatus.textContent = 'Hold the card on the reader…';
    try {
      const d = await diagnoseCard(raw);
      const verdict = d.isCascade
        ? '7-byte UID (cascade tag) — this is not a 4-byte Mifare Classic 1K.'
        : d.bccValid
          ? 'BCC OK — this card should work; the earlier error was likely transient positioning.'
          : 'BCC MISMATCH — malformed block-0 UID (a UID-writable "magic" card). Rewrite block 0 with a correct BCC, or use a standard Classic 1K.';
      deviceStatus.textContent =
        `ATQA: ${hex(d.atqa)}\n` +
        `UID (CL1): ${hex(d.uidCl1)}\n` +
        `BCC returned: 0x${d.bccReturned.toString(16).padStart(2, '0')}  computed: 0x${d.bccComputed.toString(16).padStart(2, '0')}\n` +
        verdict;
    } catch (e) {
      deviceStatus.textContent = `Diagnose failed: ${humanError(e)} (hold a card steady on the reader and retry)`;
    }
  });
}
