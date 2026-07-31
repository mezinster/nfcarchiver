/**
 * Owns the Chameleon Ultra device/transport for the whole app — the single
 * place `chameleon-ultra.js` is imported on the app side. Panels read the
 * shared transport via currentTransport() and react to onConnectionChange().
 */

import { ChameleonUltra, Buffer } from 'chameleon-ultra.js';
import WebbleAdapter from 'chameleon-ultra.js/plugin/WebbleAdapter';
import { SdkChameleonDevice } from '../../src/transport/sdk-chameleon-device.js';
import { AutoTransport } from '../../src/transport/auto-transport.js';
import { WebNfcTransport } from '../../src/transport/web-nfc-transport.js';
import { BrowserNdefIO, webNfcAvailable } from './browser-ndef-io.js';
import { NtagType } from '../../src/nfc/type2.js';
import type { Transport } from '../../src/transport/transport.js';
import { type RawAntiColl } from '../diagnostics.js';
import { openInspector } from './inspect-panel.js';
import { humanError } from './errors.js';
import { log } from '../../src/log/logger.js';
import { t, onLocaleChange } from '../i18n/index.js';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

let ultra: ChameleonUltra | null = null;
let transport: Transport | null = null;
let connected = false;
const listeners: Array<(connected: boolean) => void> = [];

let readerBusy = false;

/** Which reader is behind `transport`, if any. Chameleon exposes raw page
 *  access (Inspect); Web NFC does not — panels use this to adjust accordingly. */
let reader: 'chameleon' | 'web-nfc' | null = null;

export function activeReaderName(): 'chameleon' | 'web-nfc' | null {
  return reader;
}

/** Panels report when they own the reader. Two callers interleaving BLE
 *  commands on one reader can corrupt an in-flight write, which is why the
 *  Archive button already guards on its own `archiving` flag. */
export function setReaderBusy(busy: boolean): void {
  readerBusy = busy;
  updateDeviceButtons();
}

/** `#target-tag`'s selection, mapped to the NtagType Web NFC needs up front —
 *  it has no capability container, so capacity can't be discovered from the
 *  card the way the Chameleon path does. 'auto' and the Mifare Classic entry
 *  aren't valid under phone NFC (Task 7 keeps the select in sync), so both
 *  fall back to NTAG215. */
function selectedNtagType(): NtagType {
  const v = ($('target-tag') as HTMLSelectElement).value;
  if (v === 'NTAG213') return NtagType.NTAG213;
  if (v === 'NTAG216') return NtagType.NTAG216;
  return NtagType.NTAG215;
}

function updateDeviceButtons(): void {
  ($('inspect') as HTMLButtonElement).disabled =
    !connected || readerBusy || reader !== 'chameleon';
  ($('disconnect') as HTMLButtonElement).disabled = !connected || readerBusy;
  ($('inspect') as HTMLButtonElement).title =
    reader === 'web-nfc' ? t.inspectNeedsChameleon : '';
}

/** #conn is NOT marked data-i18n: it carries live state, and applyStaticText()
 *  would rewrite a live "connected" back to the disconnected text on every
 *  locale change. This module owns it and re-derives it from `connected`. */
function renderConn(): void {
  $('conn').textContent = connected ? t.statusConnected : t.statusDisconnected;
}

export function currentTransport(): Transport | null {
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

  renderConn();
  onLocaleChange(renderConn);

  if (webNfcAvailable()) ($('use-web-nfc') as HTMLButtonElement).hidden = false;

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
        reader = null;
        updateDeviceButtons();
        renderConn();
        deviceStatus.textContent = t.readerDisconnectedClickConnect;
        log.warn('device', 'Disconnected');
        for (const cb of listeners) cb(false);
      });
      // use() is async (the adapter's install() runs availability checks etc.);
      // it MUST be awaited before connect(), or this.port is still undefined.
      await ultra.use(new WebbleAdapter());
      transport = new AutoTransport(new SdkChameleonDevice(ultra));
      await transport.connect();
      connected = true;
      reader = 'chameleon';
      renderConn();
      updateDeviceButtons();
      for (const cb of listeners) cb(true);
      deviceStatus.textContent = t.connectedDot;
      log.info('device', 'Connected');
    } catch (e) {
      deviceStatus.textContent = humanError(e);
      log.error('device', 'Connect failed', { error: String(e) });
    }
  });

  $('use-web-nfc').addEventListener('click', () => {
    log.info('device', 'Using phone NFC');
    transport = new WebNfcTransport(new BrowserNdefIO(), selectedNtagType());
    reader = 'web-nfc';
    connected = true;
    renderConn();
    updateDeviceButtons();
    for (const cb of listeners) cb(true);
    deviceStatus.textContent = t.connectedPhoneNfc;
  });

  $('disconnect').addEventListener('click', async () => {
    log.info('device', 'Disconnecting');
    await transport?.disconnect();
    transport = null;
    ultra = null;
    reader = null;
    connected = false;
    renderConn();
    updateDeviceButtons();
    for (const cb of listeners) cb(false);
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
    openInspector(new SdkChameleonDevice(dev), raw, setReaderBusy);
  });
}
