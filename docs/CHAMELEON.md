# Using a Chameleon Ultra

The Android app can drive a [Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) over Bluetooth LE instead of the phone's own NFC radio. This page explains what that buys you, how to set it up, and where the limits are.

## Why bother

The phone's NFC radio and a Chameleon are not interchangeable.

| | Phone NFC | Chameleon Ultra |
|---|---|---|
| NTAG213/215/216 | ✅ | ✅ |
| MIFARE Classic 1K | Only if the phone's chipset supports it | ✅ always |
| Card inspector | ❌ impossible | ✅ |
| Raw ISO 14443-A frames | ❌ | ✅ |
| Needs a second device | No | Yes |

Two things stand out.

**MIFARE Classic works everywhere.** Classic needs the CRYPTO1 cipher, and Android exposes it only on phones whose NFC chipset happens to implement it — NXP chipsets generally do, many others do not. The app detects this and hides the option when it is unavailable. A Chameleon does CRYPTO1 in hardware, so it works regardless of which phone you own.

**Card inspection is only possible with a Chameleon.** `nfc_manager` gives no raw anticollision and no arbitrary block access, so the phone simply cannot produce a block-by-block dump. This is a permanent property of the platform, not a missing feature — which is why the Inspect button is shown but disabled under phone NFC rather than hidden.

## Setup

1. Switch the Chameleon on and keep it near the phone.
2. Enable Bluetooth on the phone.
3. In the app, tap the **reader icon** in the top bar (it shows an NFC symbol on phone NFC, a Bluetooth symbol on a Chameleon).
4. Tap **Search**. Devices advertising the Chameleon's service appear with their signal strength.
5. Tap yours to connect.

The app asks for `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on Android 12+. It does **not** ask for location: the scan permission is declared `neverForLocation`, because the app looks for one device you own and never to work out where you are.

Discovery filters on the Chameleon's service UUID rather than its name, so a renamed device is still found.

### Signal strength matters

The picker shows RSSI in dBm. Around **−90 dBm** is a weak link and every operation slows measurably — a 64-block card inspection took **14.4 seconds** at that range, about 225 ms per block, because each block is a separate Bluetooth round trip. Moving the Chameleon closer is the first thing to try if operations feel slow.

## What changes once connected

- **Archive** and **Restore** work exactly as before; they simply use the Chameleon.
- **MIFARE Classic 1K** becomes available regardless of the phone's chipset.
- **Inspect card** becomes available.
- Only one reader is ever active. Switching disconnects the previous one first.

Tap **Disconnect** on the reader screen to return to the phone's radio.

## Card inspector

With a Chameleon connected and a card on it, **Inspect card** produces a read-only dump:

- **Identity** — medium, SAK, UID, and an anticollision probe reporting ATQA, the cascade-level-1 UID and whether the card's BCC checksum agrees with its own UID. A mismatch means a malformed or UID-writable "magic" card, which is often exactly what you are trying to find out.
- **NFAR chunk** — the decoded header if one is present: version, flags, archive ID, chunk index, payload size, and a CRC32 comparison. If no chunk is found, it says *why* — bad magic, unsupported version, truncated header, or a valid NDEF record belonging to something else.
- **Raw** — one line per block (Classic) or per 4-page group (NTAG), in hex and ASCII, with sector trailers and the manufacturer block annotated.

A sector that cannot be read is **reported in place**, not omitted — an unreadable sector is itself diagnostic, and a card with one custom key is still mostly readable.

**Copy** puts the report on the clipboard; **Share** sends it as a `.txt` file. The report body is deliberately in English regardless of app language, because it is meant to be pasted into bug reports and forum posts.

**The inspector never writes.** Sector trailers are displayed but never modified, so it cannot brick a card.

## Limits

- **Android only.** iOS support is possible in principle — Bluetooth works there and a Chameleon does CRYPTO1 itself, so it would sidestep Core NFC's inability to do MIFARE Classic — but no iOS build exists.
- **Factory keys only.** The app uses the default key `FF FF FF FF FF FF` and never writes a sector trailer, so a card it has written stays readable by anything else. Cards with custom keys can be inspected (unreadable sectors are reported) but not archived to.
- **No emulation, no firmware updates.** The app only ever uses the Chameleon as a reader/writer. It never touches the DFU service.
- **One command at a time.** The protocol is strictly request/response.

## Compatibility

Cards written through a Chameleon are byte-identical to cards written by the phone or by the [web app](../webapp/). The same NFAR chunk format, the same NDEF MIME record on NTAG, the same block layout on Classic — an archive can be written with one and restored with another.

## Licensing

The Chameleon Ultra is open hardware and its host SDK is MIT-licensed. This app contains **no** Chameleon code: the wire protocol is reimplemented in Dart, which is why the app remains fully free software and stays publishable on F-Droid. Bluetooth support uses [`flutter_reactive_ble`](https://pub.dev/packages/flutter_reactive_ble) (BSD-3-Clause).

## Troubleshooting

**The device does not appear when scanning.** Check the Chameleon is on and that Bluetooth is enabled. The picker names the specific problem — permission refused, Bluetooth off, or nothing found — rather than showing an empty list.

**Connecting fails.** The Chameleon may still be connected to something else, such as the official app or a browser tab running the web app. Disconnect there first.

**Operations are slow.** Check the RSSI in the picker. Below about −85 dBm, move the devices closer.

**A card reports "auth failed" on every sector.** It uses non-factory keys — a hotel key, transit card or office badge. That is reported, not treated as an error, and a scan continues so you can carry on through a pile of cards.
