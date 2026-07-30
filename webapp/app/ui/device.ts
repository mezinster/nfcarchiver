/**
 * Owns the Chameleon Ultra device/transport for the whole app — the single
 * place `chameleon-ultra.js` is imported on the app side. Panels read the
 * shared transport via currentTransport() and react to onConnectionChange().
 */

import { ChameleonUltra, Buffer } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../../src/transport/sdk-chameleon-device.js';
import { AutoTransport } from '../../src/transport/auto-transport.js';
import { type RawAntiColl } from '../diagnostics.js';
import { openInspector } from './inspect-panel.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

let ultra: ChameleonUltra | null = null;
let transport: AutoTransport | null = null;
let connected = false;
const listeners: Array<(connected: boolean) => void> = [];

let readerBusy = false;

/** Panels report when they own the reader. Two callers interleaving BLE
 *  commands on one reader can corrupt an in-flight write, which is why the
 *  Archive button already guards on its own `archiving` flag. */
export function setReaderBusy(busy: boolean): void {
  readerBusy = busy;
  updateInspectButton();
}

function updateInspectButton(): void {
  ($('inspect') as HTMLButtonElement).disabled = !connected || readerBusy;
}

export function currentTransport(): AutoTransport | null {
  return transport;
}

export function isConnected(): boolean {
  return connected;
}

export function onConnectionChange(cb: (connected: boolean) => void): () => void {
  listeners.push(cb);
  return () => {
    const i = listeners.indexOf(cb);
    if (i >= 0) listeners.splice(i, 1);
  };
}

export function initDeviceBar(): void {
  const deviceStatus = $('device-status');

  $('connect').addEventListener('click', async () => {
    log.info('device', 'Connecting');
    try {
      ultra = new ChameleonUltra();
      // Fires when the BLE link drops (device powered off, out of range, GATT
      // lost). Flip connection state, drop the dead transport, and notify
      // listeners so the archive loop can pause and later resume.
      ultra.emitter.on('disconnected', () => {
        connected = false;
        transport = null;
        ultra = null;
        updateInspectButton();
        $('conn').textContent = 'disconnected';
        deviceStatus.textContent = 'Reader disconnected — click Connect to resume.';
        log.warn('device', 'Disconnected');
        for (const cb of listeners) cb(false);
      });
      // use() is async (the adapter's install() runs availability checks etc.);
      // it MUST be awaited before connect(), or this.port is still undefined.
      await ultra.use(new WebbleAdapter());
      transport = new AutoTransport(new SdkChameleonDevice(ultra));
      await transport.connect();
      $('conn').textContent = 'connected';
      connected = true;
      updateInspectButton();
      for (const cb of listeners) cb(true);
      deviceStatus.textContent = 'Connected.';
      log.info('device', 'Connected');
    } catch (e) {
      deviceStatus.textContent = humanError(e);
      log.error('device', 'Connect failed', { error: String(e) });
    }
  });

  $('inspect').addEventListener('click', () => {
    if (!ultra || !transport) return;
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
    openInspector(new SdkChameleonDevice(dev), raw);
  });
}
