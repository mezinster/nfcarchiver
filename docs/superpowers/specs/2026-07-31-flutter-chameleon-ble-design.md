# Chameleon Ultra over BLE in the Flutter app: selectable reader

**Date:** 2026-07-31
**Scope:** Sub-projects **A** (Chameleon BLE transport + reader seam) and **B** (reader selection UI). The card inspector is sub-project **C** and gets its own spec — it depends on A but is separable, read-only, and lower-risk.

**Goal:** Let the Android app drive a Chameleon Ultra over Bluetooth LE as an alternative to the phone's own NFC radio, with the reader selectable exactly as in the web app — and without losing F-Droid publishability.

## Why this is worth doing

The phone's radio and a Chameleon are not interchangeable. A Chameleon gives raw ISO 14443-A access, which is what makes card inspection possible at all, and it does CRYPTO1 in hardware. That last point matters more than it first appears: **`CLAUDE.md` records that iOS can never support Mifare Classic because Core NFC has no CRYPTO1 — but that is a limit of the phone's radio, not of the app.** A Chameleon over BLE bypasses it entirely. This design therefore keeps the Dart layer platform-neutral, so the App Store goal already in `CLAUDE.md` stays reachable, while only Android ships and is validated now.

## Decisions (confirmed with user)

1. **`flutter_reactive_ble`** (BSD-3-Clause) as the BLE layer.
2. **Platform-neutral Dart, Android ships first.** No iOS UI, entitlements or release work in this project.

## Decisions taken during design

3. **Adapt the Chameleon to the app's existing callback/session model — do not port the web app's `Transport`.** Reasoning below.
4. **A Chameleon handles both Mifare Classic and NTAG**, routed by SAK, matching `AutoTransport`. The user asked for parity with the web app, and a reader that errored on half a card pile would be worse than no reader.

## The licence question, answered

The user's concern was legal risk from the Chameleon. That risk is not where it looks:

- **The Chameleon Ultra is open hardware and its host SDK `chameleon-ultra.js` is MIT.** It is also unusable here, being JavaScript. What this project needs is a *reimplementation of the wire protocol in Dart*, and protocols are not copyrightable. With an MIT reference to work from, even a close port is clean, and this repository has already done exactly that once: `lib/core/mifare/card_layout.dart` is a documented port of `webapp/src/mifare/card-layout.ts`, proven byte-identical by generated fixtures.
- **The real risk is the BLE package.** `flutter_blue_plus` — the most popular choice and the one every tutorial recommends — has relicensed to a custom non-free licence requiring paid commercial use. F-Droid would reject it. Choosing it without checking would have silently ended F-Droid publication.

`flutter_reactive_ble` was verified against both bars that matter:

```
compileSdkVersion 33   minSdkVersion 21   targetSdkVersion 33
```

Its transitive native dependencies are `rxandroidble` 1.16.0 (Apache-2.0), `rxkotlin` and `rxandroid` (Apache-2.0), `kotlin-stdlib` (Apache-2.0) and `protobuf-javalite` (BSD-3-Clause — Google-authored but open source, **not** Play Services).

## Architecture

### Where the Chameleon plugs in

The web app is **pull-based**: `await transport.awaitTag()`. The Flutter app is **callback/session-based**, because `nfc_manager` wraps Android's reader-mode callbacks: `startSession(onTagDiscovered: …)`. A Chameleon over BLE is naturally pull-based — you poll it.

The tempting move is to port `Transport` into Dart and convert the notifiers to a pull model, making both codebases symmetric. **This design rejects that.** `ArchiveNotifier` and `RestoreNotifier` are shipped, hardware-validated sealed-class state machines; converting them buys no user-visible behaviour and risks all of it. Instead the Chameleon adapts to the existing shape:

```
ArchiveNotifier / RestoreNotifier      unchanged
              │
        CardReader  (new seam)
        ┌─────┴─────┐
PhoneNfcReader     ChameleonReader
(wraps today's     (BLE poll loop → fires the same
 NfcRepository)     onTagDiscovered callbacks)
                          │
                   ChameleonDevice  (new — the Dart protocol port)
                          │
                   flutter_reactive_ble
```

The cost of this choice, stated plainly: the two codebases keep different architectures, so future cross-porting stays harder than it would be under a shared `Transport`. That is accepted in exchange for not rewriting working state machines.

### `CardReader`

`CardReader` is **extracted from `NfcRepository`'s existing public API, not invented.** Every member below is copied from `lib/features/nfc/data/nfc_repository.dart` with its current signature, so `nfc_provider.dart` and both notifiers compile against the seam with no call-site edits — the only evidence that the extraction was safe.

Note especially that the two session starters are asynchronous and **return a stop closure**, *and* that a separate `stopSession` exists. Both are load-bearing and both must survive:

```dart
abstract class CardReader {
  String get name;              // 'phone-nfc' | 'chameleon-ble'
  bool get supportsRawAccess;   // true only for Chameleon — gates sub-project C
  bool get isInWriteCooldown;

  Future<void> initCapabilities();
  Future<bool> isAvailable();

  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    String alertMessage,
  });

  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(String message) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)? onTagTooSmall,
    void Function(String tappedMedium, String configuredMedium, NfcTagInfo? tagInfo)? onTagTypeMismatch,
    String alertMessage,
  });

  Future<NfcReadResult> readTag({Duration timeout});
  Future<NfcWriteResult> writeTag({required Chunk chunk, required NfcTagType configuredTagType, Duration timeout});

  void stopSession({String? message});
  void clearWriteCooldown();
}
```

Two members are **added** by this design rather than extracted: `name` and `supportsRawAccess`. Two are added to the *lifecycle* — `connect()` and `disconnect()` — because a BLE reader has a connection phase the phone radio does not. `PhoneNfcReader` implements both as no-ops, keeping the contract honest rather than special-casing callers.

`alertMessage` exists because iOS shows a system NFC sheet. It is meaningless for a Chameleon and for Android generally; `ChameleonReader` accepts and ignores it rather than the interface growing a platform conditional.

`PhoneNfcReader` is a thin delegation to the existing `NfcRepository` — no logic moves, so the phone path cannot regress. `ChameleonReader` implements the same contract over a poll loop.

`TagCodec` is **reused unchanged**. It already abstracts Mifare vs NDEF encoding and is agnostic about which radio produced the bytes — the seam that was built for `MifareTagCodec` / `NdefTagCodec` is exactly the seam this needs.

### `ChameleonDevice` — the Dart port

Seven members, mirroring `webapp/src/transport/chameleon-device.ts` (24 lines) one-for-one:

```dart
abstract class ChameleonDevice {
  bool get isConnected;
  Future<void> connect();
  Future<void> disconnect();
  Future<ScannedTag?> scanTag();                 // uid + sak, or null
  Future<Uint8List> transceive14a(Uint8List data, {bool appendCrc, bool autoSelect, bool checkResponseCrc});
  Future<Uint8List> readBlock(int block, Uint8List key);
  Future<void> writeBlock(int block, Uint8List key, Uint8List data);
}
```

### The wire protocol

The Chameleon exposes a **Nordic UART Service**:

| Role | UUID |
|---|---|
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| RX — app writes commands | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| TX — device notifies responses | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |

A DFU service (`8ec90001-…`) is also advertised and is **out of scope** — this app never touches firmware update.

Frame layout, big-endian throughout:

```
offset  size  field
0       2     SOF        0x11 0xEF      (0xEF is the LRC of 0x11)
2       2     command    uint16
4       2     status     uint16
6       2     dataLen    uint16
8       1     head LRC   lrc(bytes 2..7)
9       n     data
9+n     1     data LRC   lrc(data)
```

with `lrc(b) = (0x100 - sum(b)) & 0xFF`. Total frame length is `10 + dataLen`.

Commands needed — six. Four carry the actual card operations; the other two exist because of the mode gotcha and the connect-time liveness check below:

| Command | ID | Payload |
|---|---|---|
| `GET_APP_VERSION` | 1000 | none — used as a post-connect liveness check |
| `CHANGE_DEVICE_MODE` | 1001 | 1 byte mode |
| `HF14A_SCAN` | 2000 | none |
| `MF1_READ_ONE_BLOCK` | 2008 | `keyType(1) block(1) key(6)` |
| `MF1_WRITE_ONE_BLOCK` | 2009 | `keyType(1) block(1) key(6) data(16)` |
| `HF14A_RAW` | 2010 | options + frame |

Status values that matter: `SUCCESS = 0x01`, `HF_TAG_OK = 0x00`, `MF_ERR_AUTH = 0x06` (wrong key — a foreign card, not a fault), `PAR_ERR = 0x60`.

**The mode gotcha.** The Chameleon boots into emulation mode. Every HF operation must be preceded by a switch to **reader mode** via `CHANGE_DEVICE_MODE`, and the SDK caches the current mode to avoid re-sending it. A port that omits this gets silent failures on every command, and it is not visible from the six-method seam — only from the SDK's `assureDeviceMode` call inside each command. `ChameleonDevice.connect()` therefore sets reader mode once and asserts it, rather than leaving each call site to remember.

### Reader selection (sub-project B)

Mirrors the web app's device bar and reuses the Mifare capability pattern already in the app:

- A reader picker offering **Phone NFC** and **Chameleon (BLE)**. Phone NFC is hidden when the device has no NFC hardware; Chameleon is offered whenever Bluetooth is available.
- Choosing Chameleon opens a **device picker** listing nearby BLE devices advertising the Nordic UART service, filtered by name prefix. Web Bluetooth gave the web app a browser-supplied chooser for free; Flutter has no equivalent, so this screen is new work with no web-app counterpart to port.
- Connection state, the active reader's name, and a Disconnect action live in one place, as `#device-pill` does in the web app.
- **Exclusivity:** exactly one reader is active. Switching tears the previous one down first. This mirrors `teardownActiveReader()` in `device.ts`, which exists because a half-open session otherwise leaks — the same hazard applies to a GATT connection.
- Runtime permissions via the existing `permission_handler`: `BLUETOOTH_SCAN` (with `neverForLocation`) and `BLUETOOTH_CONNECT` on API 31+.

## F-Droid compliance

| Requirement | Status |
|---|---|
| All dependencies FOSS | ✅ BSD-3 + Apache-2.0 + BSD-3 |
| `compileSdk` stays **34** | ✅ plugin targets 33; must be re-checked on every plugin bump |
| No Google Play Services | ✅ verified |
| No location permission | ✅ `BLUETOOTH_SCAN` + `android:usesPermissionFlags="neverForLocation"` |
| No anti-features | ✅ a BLE link to hardware the user owns is not `NonFreeNet` |
| APK size | ⚠️ RxJava2 + protobuf are **not free**; must be measured, not estimated |

The size row is deliberately not given a number. An earlier estimate in this project (the localisation bundle) was wrong by nearly 2× because it was assumed rather than measured, and the same mistake must not be repeated here. The gate is: measure the APK before and after, and report the delta.

`fdroid/com.nfcarchiver.nfc_archiver.yml` needs no structural change — `pub get` already runs in `prebuild`, and the new Gradle dependencies resolve from Maven Central during `build`.

## Error handling

Chameleon-specific failures map onto the app's existing error surface rather than introducing a parallel one:

- **Not connected / GATT dropped mid-operation** → the same "reader disconnected" path the app already shows when an NFC session dies, so the archive and restore loops need no new branches.
- **`MF_ERR_AUTH`** → a foreign card, i.e. a user situation, not a fault. It must **not** count toward any retry/abort budget. This is a lesson already paid for in the web app: `web-nfc-gotchas` records that a foreign Mifare Classic (SAK 0x08 — hotel key, transit card) fails on *authentication*, not detection, so treating auth failure as a hard error aborts a healthy session.
- **Short or malformed frame** → transient RF, retried; never surfaced as "this card holds no NFAR chunk". `readBlockStrict` in `chameleon-ble.ts` exists for exactly this reason and its behaviour is ported.
- **Bluetooth off, or permission denied** → surfaced at the reader picker, not inside a scan loop.

## Testing

- **`FakeChameleonDevice`** in Dart, mirroring the web app's `FakeChameleon`: implements `ChameleonDevice` over an in-memory card so `ChameleonReader` is fully testable with no hardware and no BLE.
- **Frame codec tests** are the highest-value unit tests here — LRC computation, round-trip encode/decode, truncated frames, a frame split across BLE notifications, and garbage before the SOF (the SDK resynchronises by scanning for `0x11EF`, and a port that assumes frame-aligned notifications will fail on real hardware).
- **Cross-language fixtures.** `tool/generate_web_fixtures.dart` and `verify_web_fixtures.dart` already prove NFAR byte-compatibility between the two codebases. Command frames get the same treatment: a fixture file of encoded frames generated from the TypeScript, verified byte-for-byte by Dart tests.
- **The phone path must not regress.** `PhoneNfcReader` is pure delegation, and the existing NFC tests keep running against it unchanged — that is the evidence the refactor was safe.
- **Not testable without hardware, and stated as such:** that a real Chameleon connects, that reader mode is accepted, that `HF14A_SCAN` returns a real UID/SAK, and that block read/write round-trips on a physical card.

## Non-goals

- The **card inspector** — sub-project C, its own spec
- Chameleon **emulation** features, slots, or firmware update (DFU)
- **iOS UI, entitlements or release work** — the Dart layer stays platform-neutral, nothing more
- Any change to the NFAR format, on-tag bytes, or the archive/restore state machines
- Replacing the app's callback/session model with the web app's pull-based `Transport`
- Chameleon Lite support — untested and unowned; the design does not assume it, and `GET_APP_VERSION` gives a place to reject unsupported firmware later if needed

## Risks

- **No hardware validation path is established for this feature yet.** Every protocol detail above is read from an MIT reference implementation, not observed on a device. The frame codec and the reader-mode requirement are the two most likely places for a first-run failure.
- **BLE reliability on Android is device-specific.** GATT connection races, MTU negotiation and mid-operation drops are real and not reproducible in unit tests. The exclusivity/teardown rule exists to contain this, not to eliminate it.
- **Plugin bumps can break F-Droid silently** by raising `compileSdk` past 34. This is a recurring maintenance obligation, not a one-time check.
- **`nfc_manager` and `flutter_reactive_ble` both hold radio resources.** Nothing in this design lets both run at once, and the exclusivity rule must be enforced in code, not by convention.
