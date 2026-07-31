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

/** Bumped by teardownActiveReader() on every reader hand-off. The Chameleon's
 *  `disconnected` listener captures the epoch current when it was attached and
 *  compares it at fire time — if a hand-off has since bumped the epoch, the
 *  event belongs to a superseded session and the handler no-ops instead of
 *  stomping the state of whatever reader replaced it. Mirrors the
 *  currentAbort guard in inspect-panel.ts: a superseded session may only tear
 *  down state it still owns. */
let readerEpoch = 0;

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

/** Iterates a COPY: a listener may unsubscribe itself from inside its own
 *  callback (archive-panel's awaitReconnect does exactly that), and splicing
 *  the live array mid-iteration would skip the listener after it. */
function notify(state: boolean): void {
  for (const cb of [...listeners]) cb(state);
}

/** The one teardown path for a reader hand-off. Connect, Use phone NFC, and
 *  Disconnect all call this FIRST, so no site can forget to close the
 *  outgoing reader or leave its listeners live behind a new session.
 *
 *  Bumping the epoch before awaiting anything neutralises the Chameleon's
 *  `disconnected` listener immediately — including the case where the
 *  `disconnect()` call below is itself what triggers that event. Clearing
 *  `transport`/`ultra`/`reader`/`connected` synchronously (before the await)
 *  means nothing can observe or use the dying reader while its disconnect is
 *  in flight.
 *
 *  For the Chameleon, `transport.disconnect()` (AutoTransport ->
 *  SdkChameleonDevice -> `ultra.disconnect()`) closes the actual BLE/GATT
 *  session rather than just dropping the reference. For Web NFC it clears the
 *  cached reading and stops any in-flight scan. Either way, a throw from an
 *  already-dead link (device powered off, scan already stopped) must not
 *  block the switch to the next reader. */
async function teardownActiveReader(): Promise<void> {
  readerEpoch += 1;
  const dying = transport;
  transport = null;
  ultra = null;
  reader = null;
  connected = false;
  if (dying) {
    try {
      await dying.disconnect();
    } catch (e) {
      log.warn('device', 'Teardown disconnect failed — link likely already dead', { error: String(e) });
    }
  }
}

export function initDeviceBar(): void {
  const deviceStatus = $('device-status');

  /** Bring the whole device bar back to the disconnected state after a failed
   *  hand-off. The teardown that opened the hand-off cleared the state
   *  variables, but it deliberately renders nothing and notifies nobody (its
   *  caller normally goes straight on to connect something else). When the
   *  connect that followed it fails, that silence leaves #conn reading
   *  "connected", Disconnect/Archive enabled, and every listener still
   *  believing it is connected — a real true->false transition that fires zero
   *  callbacks.
   *
   *  Tears down again rather than just nulling the fields: the failed attempt
   *  may have got as far as an open BLE session with a live `disconnected`
   *  listener on it, and only teardownActiveReader() closes that and bumps the
   *  epoch that retires the listener. */
  const failHandOff = async (message: string): Promise<void> => {
    await teardownActiveReader();
    renderConn();
    updateDeviceButtons();
    deviceStatus.textContent = message;
    notify(false);
  };

  renderConn();
  // The Inspect tooltip is derived from `t` too, so it needs re-rendering on a
  // locale change just as much as #conn does.
  onLocaleChange(() => { renderConn(); updateDeviceButtons(); });

  if (webNfcAvailable()) ($('use-web-nfc') as HTMLButtonElement).hidden = false;

  /** Build (or rebuild) the Web NFC transport for the current #target-tag
   *  selection. Web NFC has no capability container, so the chosen NtagType is
   *  baked into the transport — which makes it stale the moment the user picks
   *  a different chip. Always routed through teardownActiveReader() so the
   *  outgoing reader is closed and its epoch retired, and always notifies, so a
   *  write loop in flight adopts the new transport (see ArchiveOrchestrator's
   *  transport-identity gate) instead of driving the retired one.
   *
   *  Epoch-guarded exactly like the Chameleon path below: connect() awaits
   *  Chrome's NFC permission prompt, and while it pends the user can start
   *  another hand-off (press Connect, or change #target-tag — that handler is
   *  fire-and-forget `void activateWebNfc()`). Without the guard the stale
   *  connect resolves afterwards and overwrites transport/reader/connected,
   *  orphaning the reader that superseded it, and leaves an armed NDEFReader
   *  nothing holds a reference to. If the epoch moved, this activation lost:
   *  close the scan it armed and return without touching shared state. */
  const activateWebNfc = async (): Promise<void> => {
    await teardownActiveReader();
    const myEpoch = readerEpoch;
    try {
      const t0 = new WebNfcTransport(new BrowserNdefIO(), selectedNtagType());
      await t0.connect();
      if (myEpoch !== readerEpoch) {
        await t0.disconnect();
        log.info('device', 'Phone NFC activation superseded — discarding the stale scan');
        return;
      }
      transport = t0;
      reader = 'web-nfc';
      connected = true;
      renderConn();
      updateDeviceButtons();
      notify(true);
      deviceStatus.textContent = t.connectedPhoneNfc;
    } catch (e) {
      await failHandOff(humanError(e));
      log.error('device', 'Phone NFC activation failed', { error: String(e) });
    }
  };

  $('connect').addEventListener('click', async () => {
    log.info('device', 'Connecting');
    await teardownActiveReader();
    const myEpoch = readerEpoch;
    try {
      ultra = new ChameleonUltra();
      // Fires when the BLE link drops (device powered off, out of range, GATT
      // lost) — including as a side effect of this module's own teardown
      // calling disconnect(). Guarded by epoch: if a later hand-off has since
      // superseded this session, this event is stale and must not stomp the
      // state of whatever reader replaced it. Otherwise, flip connection
      // state, drop the dead transport, and notify listeners so the archive
      // loop can pause and later resume.
      ultra.emitter.on('disconnected', () => {
        if (myEpoch !== readerEpoch) return;
        connected = false;
        transport = null;
        ultra = null;
        reader = null;
        updateDeviceButtons();
        renderConn();
        deviceStatus.textContent = t.readerDisconnectedClickConnect;
        log.warn('device', 'Disconnected');
        notify(false);
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
      notify(true);
      deviceStatus.textContent = t.connectedDot;
      log.info('device', 'Connected');
    } catch (e) {
      // The teardown above already dropped whatever reader was live, so this is
      // a genuine connected -> disconnected transition even though nothing here
      // "disconnected": dismissing Chrome's Bluetooth chooser while phone NFC
      // was in use must not leave the bar claiming it is still connected.
      await failHandOff(humanError(e));
      log.error('device', 'Connect failed', { error: String(e) });
    }
  });

  $('use-web-nfc').addEventListener('click', async () => {
    log.info('device', 'Using phone NFC');
    await activateWebNfc();
  });

  // The NtagType is baked into WebNfcTransport at build time, so a target-tag
  // change while phone NFC is active leaves the transport sizing chunks for the
  // OLD chip — the panel would prepare NTAG216-sized cards and the first tap
  // would silently re-chunk them down to NTAG215's (or fail every tap with
  // CardCapacityError the other way round). Rebuild it. The Chameleon reads
  // capacity from the card it taps, so its path must not be disturbed.
  $('target-tag').addEventListener('change', () => {
    if (reader !== 'web-nfc') return;
    log.info('device', 'Target tag changed — rebuilding the phone NFC transport');
    void activateWebNfc();
  });

  $('disconnect').addEventListener('click', async () => {
    log.info('device', 'Disconnecting');
    await teardownActiveReader();
    renderConn();
    updateDeviceButtons();
    notify(false);
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
