# NFC Archiver — Web

A browser port of [NFC Archiver](../README.md). It runs entirely client-side
(no server, no upload, no tracking) and uses a **Chameleon Ultra** over **Web
Bluetooth** to read and write NFAR archives on physical NFC cards from a Chromium
browser.

The bytes it writes are identical to the Flutter app's, so archives are
**interoperable in both directions**: a card written on the phone restores in the
browser and vice versa, and an NTAG written in the browser is a standard NDEF tag
readable by any NFC phone.

## Requirements

- **Node ≥ 22** for tests/build (needs `crypto.subtle` and `CompressionStream` as
  globals). Use nvm: `source ~/.nvm/nvm.sh && nvm use --lts`.
- **A Chromium browser** (Chrome/Edge) on a machine with Bluetooth. Web Bluetooth
  is not available in Firefox or iOS Safari. **Inside WSL2 there is no Bluetooth**
  — run the browser on the Windows host and point it at the dev-server URL.
- **A Chameleon Ultra** with a charged battery and BLE firmware, plus the cards
  you want to write (Mifare Classic 1K with factory keys, or NTAG213/215/216).

## Quick start

```bash
cd webapp
source ~/.nvm/nvm.sh && nvm use --lts
npm install
npm test        # runs the full unit/integration suite (no hardware needed)
npm run app     # serves http://localhost:8000
```

Open `http://localhost:8000` in Chrome/Edge, click **Connect Chameleon**, then use
the **Archive** / **Restore** tabs. See [`HARDWARE_TESTING.md`](HARDWARE_TESTING.md)
for the manual real-device checklist (BLE pairing, round-trip, cross-read).

## Features

- **Two media, auto-detected:** Mifare Classic 1K (720 B payload/card) and
  NTAG213/215/216 (Type-2 / NDEF). The transport reads each tapped tag's SAK and
  routes to the right protocol; the Archive tab has a target-tag selector (with
  capacities) that sizes the chunking.
- **Archive files or text**, with GZIP compression and AES-256-GCM + PBKDF2
  encryption, filename preservation, and a live "≈ N cards" estimate.
- **Multi-archive restore:** scan a mixed pile of cards, see every detected archive
  (encryption status + completeness), and pick a complete one to restore.
- **Diagnose card** — reads a card's raw UID + BCC (bypassing the reader's BCC
  check) to explain read failures.
- A branded, themed (light/dark), tabbed UI.

## Architecture

Vanilla TypeScript, bundled by esbuild. No UI framework; the only runtime
dependency is `chameleon-ultra.js` (MIT), confined to two files.

```
webapp/
  src/                         # dependency-free core (web-platform globals only)
    crc32 · chunk · chunker · crypto · gzip · pipeline   # byte-compatible NFAR core
    filename.ts                # Android-compatible filename wrapper
    mifare/card-layout.ts      # chunk ↔ Mifare Classic 1K blocks (47 usable = 752 B)
    nfc/ndef.ts, nfc/type2.ts  # NDEF MIME record + Type-2 TLV framing for NTAG
    transport/                 # Transport seam + implementations
      transport.ts             # Transport interface + typed errors
      chameleon-device.ts      # ChameleonDevice seam (scanTag, transceive14a, block R/W)
      chameleon-ble.ts         # Mifare Classic transport
      ntag-transport.ts        # NTAG (Type-2/NDEF) transport
      auto-transport.ts        # routes each tag by SAK → Classic or NTAG
      sdk-chameleon-device.ts  # the SDK adapter (imports chameleon-ultra.js)
  app/                         # UI (thin DOM glue over the controllers)
    controller.ts              # DOM-free archive/restore state machines (tested)
    estimate.ts                # live card-count estimate
    ui/                        # shell (tabs+theme), device (owns transport), panels
  test/                        # node:test suites + FakeChameleon + interop fixtures
```

The core (`src/` minus `transport/sdk-chameleon-device.ts`) uses only web-platform
globals, so the same files run in the browser and under `node --test`. A
`FakeChameleon` simulates both Mifare Classic and NTAG media, so every transport is
fully tested without hardware.

## Testing

- `npm test` — the full suite (NFAR core, codecs, transports vs the fake device,
  controllers, end-to-end archive→cards→restore for both media).
- **Cross-language interop** (proves phone↔browser byte-compatibility): from the
  repo root, `dart run tool/generate_web_fixtures.dart` then, after `npm run
  fixtures`, `dart run tool/verify_web_fixtures.dart` — the Dart side uses the
  Flutter app's production services, so a passing run is a real interop proof.
- The NDEF/Type-2 byte formats are pinned by byte-exact unit tests (the cross-compat
  guard); a real phone reading a Chameleon-written NTAG is a manual checklist item.

## Notes & known follow-ups

- `chameleon-ultra.js` validates arguments at runtime in ways the type-checker can't
  see: its `Buffer.isBuffer` rejects plain `Uint8Array` (the adapter converts with
  `Buffer.from`), and `cmdHf14aScan()` throws on an empty field. The
  `ChameleonDevice` seam absorbs these.
- Marginal RF coupling (a card pressed flat vs a few mm off the reader) can make the
  scan return transient BCC/parity/collision errors; the transport treats those as
  "no tag yet" and keeps polling.
- **Deferred:** localization (7 locales), an IndexedDB-backed file manager (the Files
  tab is a placeholder), phone-native **Web NFC** writing (Android Chrome, no
  Chameleon — reuses `nfc/ndef.ts`), NTAG blank-tag CC formatting (factory/
  NDEF-formatted tags are assumed), and a device-disconnect path.

## License

MIT (see [`../LICENSE`](../LICENSE)).
