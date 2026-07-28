# Web App — NTAG (Type-2 / NDEF) Support via the Chameleon Ultra

**Date:** 2026-07-28
**Status:** Draft for review
**Base:** branch `webapp-ntag-transport` (off `webapp-nfar-core-prototype`, PR #34)
**Predecessor:** iterations 1–4 (NFAR core, Mifare transport, metadata, branded shell)

## Goal

Let the web app read and write NFAR chunks on **NTAG213/215/216** tags using the
Chameleon Ultra's reader (over BLE), in the **NDEF format the Android app uses**,
so a tag written by the Chameleon-web app is readable by the Android app and by
any NFC phone — and vice versa. Restore auto-detects the tag type; archive picks
a target type.

## Non-Goals (this sub-project)

- **No Web NFC** (`NDEFReader`) yet — that phone-native path is a later sub-project. The shared NDEF codec built here is reused by it.
- **No plain MIFARE Ultralight** (non-NTAG) — NTAG213/215/216 only.
- **No blank-tag formatting** — assume factory/NDEF-formatted NTAGs (Capability Container already set); we write the NDEF area from page 4. Formatting a virgin tag's CC is a possible follow-up.
- No change to the NFAR core or the archive/restore controllers' logic (chunk bytes are identical across media).

## Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| NDEF format | **Match the NFC-Forum NDEF standard byte-for-byte** (which is what Android's `nfc_manager.createMime` emits) → cross-compatible with the phone app and any NFC reader |
| Tag routing | **Auto-detect** from the scan SAK (Classic 1K = `0x08`; Type-2/NTAG = `0x00`) and route to the right transport |
| Scope | NTAG213/215/216 via Chameleon; Web NFC deferred |
| Archive sizing | **Target-tag selector** on the Archive tab sets the chunk payload size; restore stays fully auto |

## The format (verbatim from the Android app + the NDEF/Type-2 specs)

The Android `NdefFormatter.chunkToNdef` (`lib/features/nfc/domain/ndef_formatter.dart`) is:
`NdefRecord.createMime('application/vnd.nfcarchiver.chunk', chunk.toBytes())` →
a one-record NDEF message. The record bytes are fully determined by the NFC-Forum
NDEF spec, so matching the standard *is* matching Android.

**One NDEF MIME record wrapping the chunk:**
```
byte 0: flags = MB | ME | SR? | TNF(0x02 media)   → 0xD2 short (payload<256), 0xC2 long
byte 1: TYPE LENGTH = 33
payload length: 1 byte (short) or 4 bytes big-endian (long)
TYPE: "application/vnd.nfcarchiver.chunk" (33 bytes ASCII)
PAYLOAD: the exact NFAR chunk bytes (encodeChunk output — unchanged from the Mifare path)
```

**NFC-Forum Type-2 TLV wrapper** (written from NTAG page 4):
```
0x03 <len> <ndef-message-bytes> 0xFE
  len = 1 byte if the NDEF message < 255 bytes, else 0xFF followed by a 2-byte big-endian length
  0xFE = terminator TLV
```

**Reading:** read the tag's user memory, find the `0x03` NDEF TLV, parse the NDEF
message, take the MIME record's payload (or, as Android does, any record whose
payload starts with the NFAR magic) → `decodeChunk`. One chunk per tag.

## NTAG capacities

| Type | User memory | Detect (`GET_VERSION` storage byte) |
|---|---|---|
| NTAG213 | 144 B (pages 4–39) | `0x0F` |
| NTAG215 | 504 B (pages 4–129) | `0x11` |
| NTAG216 | 888 B (pages 4–225) | `0x13` |

The chunk **payload size** per type is derived like Android's
`maxPayloadForNdefCapacity`: `user_memory − TLV_overhead − NDEF_record_overhead
(3 short / 6 long) − MIME(33) − NFAR(32)`. Exact per-type values are pinned as
constants with unit tests in the plan (roughly: 213 ≈ 73 B, 215 ≈ 430 B,
216 ≈ 814 B of chunk payload). A tag holds exactly one chunk; a multi-tag archive
shares one archive ID, so any reader reassembles it regardless of how it was
split — cross-compat is a per-tag byte-format property, not a split property.

## Architecture

Reuse the core + controllers; add pure codecs, an NTAG transport, and an
auto-routing transport. New files under `webapp/src/nfc/` and `webapp/src/transport/`.

- **`src/nfc/ndef.ts`** (pure, tested) — `encodeNdefMime(payload): Uint8Array`
  (one MIME record for our type) and `decodeNdefMime(bytes): Uint8Array` (return
  the NFAR-chunk payload of the first matching record; throw `NdefFormatError`
  otherwise). Byte-exact.
- **`src/nfc/type2.ts`** (pure, tested) — `wrapType2Tlv(ndef): Uint8Array` /
  `readType2Ndef(memory): Uint8Array` (find the `0x03` TLV); the NTAG type enum +
  per-type capacity + chunk payload size; and `detectNtagType(getVersionResp)`.
- **`ChameleonDevice` seam** gains: `scanTag()` now returns `{ uid; sak } | null`
  (SdkChameleonDevice reads `sak` from `cmdHf14aScan`); a new
  `transceive14a(data, opts?): Promise<Uint8Array>` mapping to `cmdHf14aRaw`
  (the command the BCC diagnostic already uses). `ChameleonBleTransport` updates
  to the new `scanTag` shape (reads `.uid`).
- **`src/transport/ntag-transport.ts`** — `NtagTransport implements Transport`:
  `awaitTag` (poll scan, `GET_VERSION` → type + capacity), `peekIsNfar` (read the
  NDEF area, test for our record), `readChunk` (Type-2 READ `0x30` pages → TLV →
  NDEF → chunk), `writeChunk` (chunk → NDEF → TLV → WRITE `0xA2` pages, then
  read-back verify).
- **`src/transport/auto-transport.ts`** — `AutoTransport implements Transport`:
  owns one `ChameleonDevice` plus a `ChameleonBleTransport` and an
  `NtagTransport`. `awaitTag` scans, reads SAK, sets the active delegate
  (`0x08`→Classic, `0x00`→NTAG, else a typed "unsupported tag" error), and
  returns the tag; `peekIsNfar`/`readChunk`/`writeChunk` forward to the active
  delegate (no re-scan). The UI uses `AutoTransport`, so archive/restore/
  multi-archive work across both media transparently.
- **`FakeChameleon`** (test double) extended to simulate an NTAG: respond to
  `GET_VERSION`, and to Type-2 READ/WRITE page commands over an in-memory NTAG
  image — so `NtagTransport` and `AutoTransport` are fully hardware-free testable.

## Controller / UI changes

- `ArchiveController.prepare` and `estimateCardCount` gain a **`payloadSize`**
  parameter (currently hardcoded to `CARD_PAYLOAD_SIZE`/720). Restore is
  unchanged (it reads whatever chunk a tag holds).
- **Archive tab:** a **target-tag selector** (Mifare Classic 1K / NTAG213 / 215 /
  216) that sets `payloadSize` for chunking and the live counter. The transport
  still auto-routes by SAK per tap and rejects a tapped tag that is the wrong
  type or too small for the chunk (typed error → friendly message).
- **About tab:** supported-tags copy updated to "Mifare Classic 1K and
  NTAG213/215/216, via a Chameleon Ultra."
- `device.ts` constructs an `AutoTransport` (wrapping the SDK device) instead of a
  bare `ChameleonBleTransport`.

## Error Handling

New typed errors as needed: `NdefFormatError` (bad/missing NDEF record),
`UnsupportedTagError` (SAK not Classic/NTAG), `CardCapacityError` reused when a
chunk exceeds the tapped NTAG's capacity. Mapped to friendly messages in
`humanError`.

## Testing

- **`ndef.test.ts` / `type2.test.ts`** — byte-exact encode assertions (flags,
  type-length, MIME string, short vs long payload-length, the TLV bytes and
  terminator), round-trip decode, and rejection of malformed input.
- **`NtagTransport` contract test** against `FakeChameleon`: write an
  NDEF-wrapped chunk to a simulated NTAG215, read it back byte-identical;
  capacity/`peekIsNfar` behavior; oversize rejection.
- **`AutoTransport` routing test**: a `0x08` SAK routes to the Classic delegate,
  `0x00` to the NTAG delegate, an unknown SAK throws `UnsupportedTagError`.
- **End-to-end**: archive a payload at an NTAG payload size → write to fake
  NTAGs → restore → byte-identical (reusing the pipeline/controllers).
- **Cross-compat**: the NDEF/Type-2 unit tests pin the exact standard bytes;
  true device cross-read (Chameleon-web writes, phone reads the NDEF) is a manual
  `HARDWARE_TESTING.md` checklist item.
- All existing tests stay green; the core/controllers are unchanged except the
  additive `payloadSize` parameter.

## Risks

- **Type-2 write mechanics on real hardware** (page-by-page `0xA2` writes,
  read-back timing, factory CC assumptions) are unproven until the hardware
  checklist runs; the codecs and transport logic are fully unit-tested against a
  fake first.
- **`scanTag` return-shape change** ripples to `ChameleonBleTransport` and
  `FakeChameleon` — small, contained updates covered by their existing tests.
- **NDEF standard fidelity**: byte-exact unit tests are the guard; if a real
  phone rejects a written tag, the discrepancy is in these pinned bytes and is
  cheap to locate.
