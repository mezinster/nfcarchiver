# Chameleon Ultra over BLE — Implementation Plan (A + B + C-core)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive a Chameleon Ultra over BLE as a selectable alternative to the phone's NFC radio, and land the card inspector's dependency-free core, without breaking F-Droid and without changing the phone path's behaviour.

**Architecture:** A `ChameleonDevice` interface and a `FakeChameleonDevice` land first, so the inspector core (sub-project C) can be written and fully tested before any BLE code exists. Then the wire protocol, then a `CardReader` seam extracted from `NfcRepository`, then the reader-selection UI. When BLE finally runs, the protocol is the only untested thing left.

**Tech Stack:** Flutter, Dart, Riverpod, `flutter_reactive_ble` (BSD-3-Clause), `flutter_test`.

**Specs:**
- A + B — `docs/superpowers/specs/2026-07-31-flutter-chameleon-ble-design.md`
- C — `docs/superpowers/specs/2026-07-31-flutter-card-inspector-design.md`

## Global Constraints

1. **F-Droid must keep building.** `compileSdk` stays **34** — never raise it. `flutter_reactive_ble` targets 33, which is compatible; re-verify on any version bump.
2. **Only `flutter_reactive_ble` is added to `pubspec.yaml`.** No other new dependency in this plan. Never add `flutter_blue_plus` — its licence is non-free and F-Droid would reject the app.
3. **The phone NFC path must not change behaviour.** `PhoneNfcReader` is pure delegation to the existing `NfcRepository`; all existing tests keep passing untouched, and that is the evidence the extraction was safe.
4. **Exactly one reader is active at a time.** Switching tears the previous one down first. `nfc_manager` and `flutter_reactive_ble` must never hold radios concurrently.
5. **The inspector is read-only.** Nothing in `lib/core/inspect/` may write to a card. Sector trailers are read and displayed, never written.
6. **All multi-byte protocol fields are big-endian.**
7. **New UI strings go in `lib/l10n/app_en.arb` and all six translations**, then `flutter gen-l10n`. The inspector *report body* stays English by design — only chrome is translated.
8. **`describeNfar` must stay more tolerant than `Chunk.fromBytes`.** It reports malformed input; it must never throw on it, and must never be "simplified" to reuse the production decoder.
9. Run `flutter gen-l10n` before `flutter test` when ARB files changed. Verify with `flutter analyze` and `flutter test`.
10. Baseline: **all existing tests in `test/` pass**. No task may reduce that.

## Shared test helpers

Several tasks' tests use the same helpers. They live in **`test/support/helpers.dart`**, created as part of Task 1, so no task invents its own copy:

```dart
/// A DumpCallbacks that records nothing — for tests asserting on DumpResult only.
DumpCallbacks collectUnits() => DumpCallbacks(onUnit: (_, __, ___) {});

/// A real, valid NFAR chunk built with the production Chunk model, so the
/// fixture can never drift from the format it is meant to represent.
Uint8List validChunkBytes({int payloadLength = 32});

/// The Chunk behind validChunkBytes(), for write-path tests.
Chunk aChunk();

/// Yield to the event loop once.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Poll until [cond] holds or [timeout] elapses; fails the test on timeout so
/// a hung poll loop surfaces as a named failure rather than a suite that hangs.
Future<void> pumpUntil(bool Function() cond, {Duration timeout = const Duration(seconds: 2)});
```

---

## Phase 1 — Shared foundation and the inspector core

### Task 1: `ChameleonDevice`, `CancellationToken`, `FakeChameleonDevice`

**Files:**
- Create: `lib/core/chameleon/chameleon_device.dart`
- Create: `lib/core/chameleon/cancellation_token.dart`
- Create: `test/support/fake_chameleon_device.dart`
- Create: `test/support/helpers.dart` (shared across Tasks 2–9 — see Shared test helpers)
- Test: `test/fake_chameleon_device_test.dart`

**Interfaces:**
- Produces: `ChameleonDevice`, `ScannedTag`, `CancellationToken`, `FakeChameleonDevice`, `factoryKeyA`. Every later task depends on these.

- [ ] **Step 1: Write the interface**

```dart
// lib/core/chameleon/chameleon_device.dart
import 'dart:typed_data';

/// A tag seen in the reader's field. SAK 0x08 = Mifare Classic 1K, 0x00 = NTAG/Type-2.
class ScannedTag {
  const ScannedTag({required this.uid, required this.sak, required this.atqa});
  final Uint8List uid;
  final int sak;
  final Uint8List atqa;
}

/// Narrow seam over a Chameleon Ultra. Mirrors
/// webapp/src/transport/chameleon-device.ts one-for-one so the two codebases
/// stay portable to each other.
abstract class ChameleonDevice {
  bool get isConnected;
  Future<void> connect();
  Future<void> disconnect();

  /// The tag in the field, or null if none.
  Future<ScannedTag?> scanTag();

  /// Send a raw ISO 14443-A frame and return the response.
  Future<Uint8List> transceive14a(
    Uint8List data, {
    bool appendCrc = false,
    bool autoSelect = false,
    bool checkResponseCrc = false,
    bool keepRfField = false,
    int dataBitLength = 0,
  });

  /// Read a 16-byte Mifare Classic block, authenticating with key A.
  Future<Uint8List> readBlock(int block, Uint8List key);

  /// Write a 16-byte Mifare Classic block, authenticating with key A.
  Future<void> writeBlock(int block, Uint8List key, Uint8List data);
}

final Uint8List factoryKeyA =
    Uint8List.fromList(const [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);

/// Wrong key for a sector — a foreign card, i.e. a user situation, NOT a
/// fault. Callers must never count this toward a retry or abort budget.
class CardAuthException implements Exception {
  const CardAuthException(this.message);
  final String message;
  @override
  String toString() => 'CardAuthException: $message';
}

class CardReadException implements Exception {
  const CardReadException(this.message);
  final String message;
  @override
  String toString() => 'CardReadException: $message';
}

class UnsupportedTagException implements Exception {
  const UnsupportedTagException(this.message);
  final String message;
  @override
  String toString() => 'UnsupportedTagException: $message';
}

class TagTimeoutException implements Exception {
  const TagTimeoutException(this.message);
  final String message;
  @override
  String toString() => 'TagTimeoutException: $message';
}
```

- [ ] **Step 2: Write the cancellation token**

Dart has no `AbortSignal`. This is the minimum that replaces one — deliberately not a new dependency.

```dart
// lib/core/chameleon/cancellation_token.dart
/// Cooperative cancellation for long operations (a 64-block dump).
///
/// Also the ownership marker for superseded runs: a second inspection must not
/// let the first one's in-flight callbacks write into its state. Callers check
/// `isCancelled` inside every callback, not only before starting — the damage
/// is done by callbacks already scheduled.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
```

- [ ] **Step 3: Write the failing test for the fake**

```dart
// test/fake_chameleon_device_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'support/fake_chameleon_device.dart';

void main() {
  test('a Classic card round-trips a block through the fake', () async {
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();
    final data = Uint8List.fromList(List<int>.generate(16, (i) => i));
    await dev.writeBlock(4, factoryKeyA, data);
    expect(await dev.readBlock(4, factoryKeyA), equals(data));
  });

  test('a sector with a non-factory key raises CardAuthException', () async {
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {1: Uint8List.fromList(const [1, 2, 3, 4, 5, 6])},
    );
    await dev.connect();
    expect(() => dev.readBlock(4, factoryKeyA), throwsA(isA<CardAuthException>()));
  });

  test('scanTag reports SAK 0x08 for Classic and 0x00 for NTAG', () async {
    expect((await FakeChameleonDevice.classic1k().scanTag())!.sak, 0x08);
    expect((await FakeChameleonDevice.ntag215().scanTag())!.sak, 0x00);
  });

  test('an empty field returns null rather than throwing', () async {
    final dev = FakeChameleonDevice.classic1k()..removeCard();
    expect(await dev.scanTag(), isNull);
  });
}
```

- [ ] **Step 4: Run the test to verify it fails**

`flutter test test/fake_chameleon_device_test.dart` → FAIL, `fake_chameleon_device.dart` not found.

- [ ] **Step 5: Implement `FakeChameleonDevice`**

In `test/support/fake_chameleon_device.dart`, implementing `ChameleonDevice` over in-memory storage. Named constructors `classic1k({Map<int, Uint8List>? sectorKeys})` and `ntag215()`, plus `removeCard()`.

Behaviour it must reproduce:
- `readBlock`/`writeBlock` throw `CardAuthException` when the supplied key does not match that sector's key (default: factory key A everywhere).
- `transceive14a` supports the NTAG `READ` command (`0x30 page`), returning **4 pages (16 bytes)**.
- **It must NOT wrap at the end of memory.** A real NTAG READ wraps around to page 0; this fake returns a short slice instead. That difference is deliberate and is what exercises the "short read is legitimate on the final group only" branch in Task 3. Document it in a comment — an implementer who "fixes" the fake to wrap silently removes that test's value.

- [ ] **Step 6: Run the test to verify it passes**

`flutter test test/fake_chameleon_device_test.dart` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/core/chameleon test/support/fake_chameleon_device.dart test/fake_chameleon_device_test.dart
git commit -m "feat(chameleon): device seam, cancellation token and in-memory fake"
```

---

### Task 2: `describeNfar` — the tolerant header reader

**Files:**
- Create: `lib/core/inspect/nfar_describe.dart`
- Test: `test/inspect_nfar_describe_test.dart`

**Interfaces:**
- Consumes: `NfarHeaderSize` / `NfarHeaderOffset` from `lib/core/constants/nfar_format.dart`
- Produces: `NfarDescription` (`NfarAbsent` | `NfarPresent`), `describeNfar(Uint8List, {int? capacityBytes})`

Port of `webapp/src/inspect/nfar-describe.ts`.

- [ ] **Step 1: Write the failing tests**

The tolerance cases *are* the feature, so each asserts a **reported** description, never a throw.

```dart
// test/inspect_nfar_describe_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/inspect/nfar_describe.dart';

void main() {
  test('a blank card is reported absent, not thrown', () {
    final d = describeNfar(Uint8List(64));
    expect(d, isA<NfarAbsent>());
    expect((d as NfarAbsent).reason, isNotEmpty);
  });

  test('a truncated header is described, not thrown', () {
    // Correct magic, then nothing — the exact input Chunk.fromBytes rejects.
    final d = describeNfar(Uint8List.fromList([0x4e, 0x46, 0x41, 0x52, 0x01]));
    expect(d, isA<NfarAbsent>());
  });

  test('a valid chunk reports a matching CRC', () {
    final d = describeNfar(validChunkBytes()) as NfarPresent;
    expect(d.crcValid, isTrue);
    expect(d.crcStored, equals(d.crcComputed));
    expect(d.warnings, isEmpty);
  });

  test('a corrupted payload reports crcValid false WITHOUT throwing', () {
    final bytes = validChunkBytes();
    bytes[bytes.length - 1] ^= 0xff;
    final d = describeNfar(bytes) as NfarPresent;
    expect(d.crcValid, isFalse);
  });

  test('a chunk whose payload is cut short reports null CRC, not false', () {
    // Nothing to compare against is not the same as a mismatch, and an
    // inspector must not claim corruption it cannot prove.
    final bytes = validChunkBytes();
    final d = describeNfar(Uint8List.sublistView(bytes, 0, bytes.length - 4))
        as NfarPresent;
    expect(d.crcValid, isNull);
    expect(d.warnings, isNotEmpty);
  });

  test('an unknown version is reported with a warning, still parsed', () {
    final bytes = validChunkBytes();
    bytes[4] = 0x09;
    final d = describeNfar(bytes) as NfarPresent;
    expect(d.version, 0x09);
    expect(d.warnings, isNotEmpty);
  });
}
```

`validChunkBytes()` is a helper in the test file building a real NFAR chunk with the existing `Chunk` model, so the fixture cannot drift from the format.

- [ ] **Step 2: Run to verify failure**

`flutter test test/inspect_nfar_describe_test.dart` → FAIL, file not found.

- [ ] **Step 3: Implement**

Port `nfar-describe.ts`. Sealed classes:

```dart
sealed class NfarDescription { const NfarDescription(); }

class NfarAbsent extends NfarDescription {
  const NfarAbsent(this.reason);
  final String reason;
}

class NfarPresent extends NfarDescription {
  const NfarPresent({
    required this.version, required this.flags,
    required this.compressed, required this.encrypted,
    required this.archiveId, required this.chunkIndex,
    required this.totalChunks, required this.payloadSize,
    required this.totalLength,
    required this.crcStored, required this.crcComputed, required this.crcValid,
    required this.warnings,
  });
  final int version, flags, chunkIndex, totalChunks, payloadSize, totalLength;
  final bool compressed, encrypted;
  final String archiveId;
  final int? crcStored, crcComputed;   // null when not computable
  final bool? crcValid;                // null when not computable
  final List<String> warnings;
}
```

Reuse `ChecksumService.instance` for CRC32 — note it is a **private-constructor singleton**, so it is `.instance`, never `ChecksumService()`.

- [ ] **Step 4: Run to verify pass** — `flutter test test/inspect_nfar_describe_test.dart`

- [ ] **Step 5: Commit** — `git commit -m "feat(inspect): tolerant NFAR header description"`

---

### Task 3: `dumpCard` — Classic and NTAG

**Files:**
- Create: `lib/core/inspect/card_dump.dart`
- Test: `test/inspect_card_dump_test.dart`

**Interfaces:**
- Consumes: `ChameleonDevice`, `CancellationToken`, `FakeChameleonDevice`
- Produces: `DumpUnit`, `DumpMeta`, `DumpResult`, `UnitKind`, `UnitFailure`, `dumpCard(...)`

Port of `webapp/src/inspect/card-dump.ts`.

- [ ] **Step 1: Write the failing tests**

```dart
void main() {
  test('a Classic dump yields 64 units with block 0 as manufacturer', () async {
    final r = await dumpCard(FakeChameleonDevice.classic1k(), _collect());
    expect(r.units.length, 64);
    expect(r.units[0].kind, UnitKind.manufacturer);
    expect(r.units[3].kind, UnitKind.trailer);   // block % 4 == 3
    expect(r.units[4].kind, UnitKind.data);
    expect(r.aborted, isFalse);
    expect(r.cardLost, isFalse);
  });

  test('an unreadable sector is reported, not fatal, and the dump continues', () async {
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {1: Uint8List.fromList(const [9, 9, 9, 9, 9, 9])});
    final r = await dumpCard(dev, _collect());
    expect(r.units.length, 64, reason: 'every block still reported');
    expect(r.units[4].failure, UnitFailure.authFailed);
    expect(r.units[4].bytes, isNull);
    expect(r.units[0].bytes, isNotNull, reason: 'other sectors unaffected');
  });

  test('an NTAG dump groups four pages per unit and marks group 0 as cc', () async {
    final r = await dumpCard(FakeChameleonDevice.ntag215(), _collect());
    expect(r.units[0].kind, UnitKind.cc,
        reason: 'group 0 carries UID, lock bytes AND the capability container');
    expect(r.units[0].index, 0);
    expect(r.units[1].index, 4, reason: 'index is the STARTING page');
    expect(r.units[1].kind, UnitKind.data);
  });

  test('an unsupported SAK is rejected', () async {
    final dev = FakeChameleonDevice.classic1k()..overrideSak(0x20);
    expect(() => dumpCard(dev, _collect()), throwsA(isA<UnsupportedTagException>()));
  });

  test('cancelling mid-dump returns a partial result marked aborted', () async {
    final token = CancellationToken();
    final r = await dumpCard(FakeChameleonDevice.classic1k(),
        DumpCallbacks(onUnit: (u, done, total) { if (done == 5) token.cancel(); }),
        token: token);
    expect(r.aborted, isTrue);
    expect(r.units.length, lessThan(64));
  });

  test('a card removed mid-dump marks cardLost and fills the rest as notRead', () async {
    final dev = FakeChameleonDevice.classic1k()..failFromBlock(10);
    final r = await dumpCard(dev, _collect());
    expect(r.cardLost, isTrue);
    expect(r.units.last.failure, UnitFailure.notRead);
  });
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement**

Route by SAK exactly as the TypeScript does: `0x08` → Classic, `0x00` → NTAG, anything else → `UnsupportedTagException`. `scanTag()` returning null → `TagTimeoutException`.

Classic: 64 blocks, one unit each; `classicKind(block)` = `manufacturer` for 0, `trailer` when `block % 4 == 3`, else `data`.

NTAG: read in **4-page groups** via `transceive14a([0x30, startPage], autoSelect: true, appendCrc: true, checkResponseCrc: true)`. Group 0 is `cc`; the rest `data`. `index` is the starting page.

**The short-read rule, ported exactly:** a response shorter than the wanted `pagesHere * 4` bytes is acceptable **only on the final group** (a real READ wraps to page 0; the fake returns a short slice). Anywhere else it is `UnitFailure.shortRead` — marginal RF coupling, not content. Same symptom, opposite meaning, told apart by position.

On a non-auth exception: set `cardLost`, fill every remaining unit with `UnitFailure.notRead` (still calling `onUnit` for each so the UI stays consistent), and stop.

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit** — `git commit -m "feat(inspect): Classic and NTAG card dump"`

---

### Task 4: `hex_view` formatters + cross-language fixture

**Files:**
- Create: `lib/core/inspect/hex_view.dart`
- Create: `tool/generate_inspect_fixtures.dart` (Dart side of the check)
- Create: `test/fixtures/inspect_report.txt` (generated from TypeScript)
- Test: `test/inspect_hex_view_test.dart`

**Interfaces:**
- Produces: `formatUnitRow`, `formatIdentity`, `formatNfar`, `formatReport`

- [ ] **Step 1: Generate the reference fixture from the web app**

In `webapp/`, add a small script that builds a fixed synthetic Classic card, runs `dumpCard` against `FakeChameleon`, and writes `formatReport(...)` output to `../test/fixtures/inspect_report.txt`. Run it once and commit the artefact.

```bash
cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npx tsx tool/write-inspect-fixture.ts
```

- [ ] **Step 2: Write the failing test**

```dart
test('formatReport matches the TypeScript byte for byte', () async {
  final expected = await File('test/fixtures/inspect_report.txt').readAsString();
  // Same synthetic card the TypeScript fixture writer used: block b of sector
  // s holds bytes (0x42 + b) mod 256, and the first usable blocks carry a
  // real NFAR chunk. FakeChameleonDevice.classic1k(seed:) builds exactly this.
  final dev = FakeChameleonDevice.classic1k(seed: 0x42);
  final result = await dumpCard(dev, collectUnits());
  // The NFAR description is built from the dumped data blocks, not re-read
  // from the device — the report must describe what the dump actually saw.
  final assembled = assembleUsableBytes(result);
  final actual = formatReport(result, describeNfar(assembled), await diagnoseCard(dev));
  expect(actual, equals(expected));
});
```

`assembleUsableBytes(DumpResult)` is a small helper in `hex_view.dart` that concatenates the bytes of successfully-read usable blocks in order, skipping failures — the inspector describes what it managed to read, never what it assumes is there.

Plus unit tests for `formatUnitRow` (a data block, an auth-failed block, a trailer) and `formatNfar` (present, absent, CRC invalid).

- [ ] **Step 3: Run to verify failure**

- [ ] **Step 4: Implement the formatters**

Port `hex-view.ts`. Hex is uppercase, ASCII column renders bytes `0x20–0x7e` literally and everything else as `.`, matching the TypeScript exactly — the fixture test is what proves it.

- [ ] **Step 5: Run to verify pass**

- [ ] **Step 6: Commit** — `git commit -m "feat(inspect): report formatters, verified against TypeScript fixture"`

---

### Task 5: `diagnoseCard` — the identity probe

**Files:**
- Create: `lib/core/inspect/diagnose_card.dart`
- Test: `test/inspect_diagnose_card_test.dart`

**Interfaces:**
- Consumes: a narrow `RawAntiColl`-style seam — satisfied by `ChameleonDevice.transceive14a`
- Produces: `CardDiagnosis`, `diagnoseCard(...)`

Port of `webapp/app/diagnostics.ts`.

- [ ] **Step 1: Write the failing tests**

```dart
test('a well-formed 4-byte UID card has a consistent BCC', () async {
  final d = await diagnoseCard(FakeChameleonDevice.classic1k());
  expect(d.bccValid, isTrue);
  expect(d.bccReturned, equals(d.bccComputed));
  expect(d.isCascade, isFalse);
});

test('a 7-byte UID card is reported as cascade', () async {
  final d = await diagnoseCard(FakeChameleonDevice.ntag215());
  expect(d.isCascade, isTrue, reason: 'uidCl1[0] == 0x88 marks a cascade tag');
});

test('an inconsistent BCC is reported, not thrown — that is the finding', () async {
  final d = await diagnoseCard(FakeChameleonDevice.classic1k()..corruptBcc());
  expect(d.bccValid, isFalse);
});
```

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** — REQA (`0x26`, 7 bits) then anticollision CL1 (`0x93 0x20`); BCC is the XOR of the four UID bytes.
- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** — `git commit -m "feat(inspect): anticollision identity probe"`

---

## Phase 2 — The BLE transport

### Task 6: The frame codec

**Files:**
- Create: `lib/core/chameleon/chameleon_frame.dart`
- Test: `test/chameleon_frame_test.dart`

**Interfaces:**
- Produces: `encodeFrame(int cmd, Uint8List data)`, `FrameParser` (incremental), `ChameleonFrame(cmd, status, data)`, `ChameleonCmd` constants

This is the highest-risk pure code in the plan and gets the most tests.

- [ ] **Step 1: Write the failing tests**

```dart
void main() {
  test('lrc is the two-s complement of the byte sum', () {
    expect(lrc(Uint8List.fromList(const [0x11])), 0xEF);
  });

  test('an encoded frame has the documented layout', () {
    final f = encodeFrame(1000, Uint8List(0));
    expect(f.sublist(0, 2), equals([0x11, 0xEF]));       // SOF + its LRC
    expect(f.sublist(2, 4), equals([0x03, 0xE8]));       // cmd 1000, big-endian
    expect(f.sublist(4, 6), equals([0x00, 0x00]));       // status
    expect(f.sublist(6, 8), equals([0x00, 0x00]));       // dataLen
    expect(f[8], lrc(f.sublist(2, 8)));                  // head LRC
    expect(f.length, 10);                                // 10 + dataLen
  });

  test('a frame round-trips through the parser', () {
    final p = FrameParser();
    final frames = p.feed(encodeFrame(2000, Uint8List.fromList([1, 2, 3])));
    expect(frames.single.cmd, 2000);
    expect(frames.single.data, equals([1, 2, 3]));
  });

  test('a frame split across notifications is reassembled', () {
    // BLE delivers arbitrary chunks; assuming frame-aligned notifications is
    // the single most likely way this port fails on real hardware.
    final whole = encodeFrame(2000, Uint8List.fromList(List.filled(30, 7)));
    final p = FrameParser();
    expect(p.feed(whole.sublist(0, 5)), isEmpty);
    expect(p.feed(whole.sublist(5, 12)), isEmpty);
    expect(p.feed(whole.sublist(12)).single.cmd, 2000);
  });

  test('two frames in one notification both emerge', () {
    final p = FrameParser();
    final buf = Uint8List.fromList(
        [...encodeFrame(1000, Uint8List(0)), ...encodeFrame(2000, Uint8List(0))]);
    expect(p.feed(buf).map((f) => f.cmd), equals([1000, 2000]));
  });

  test('garbage before the SOF is skipped, and the frame still parses', () {
    final p = FrameParser();
    final buf = Uint8List.fromList([0xAA, 0xBB, ...encodeFrame(1000, Uint8List(0))]);
    expect(p.feed(buf).single.cmd, 1000);
  });

  test('a corrupt head LRC does not desynchronise the parser forever', () {
    // The reference resynchronises by advancing ONE byte and re-scanning for
    // 0x11EF. Dropping the whole buffer instead would lose a good frame that
    // follows corruption in the same notification.
    final good = encodeFrame(1000, Uint8List(0));
    final bad = Uint8List.fromList(good)..[8] ^= 0xff;
    final p = FrameParser();
    expect(p.feed(Uint8List.fromList([...bad, ...good])).map((f) => f.cmd),
        contains(1000));
  });
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement**

```
offset  size  field
0       2     SOF        0x11 0xEF   (0xEF == lrc([0x11]))
2       2     command    uint16 BE
4       2     status     uint16 BE
6       2     dataLen    uint16 BE
8       1     head LRC   lrc(bytes 2..7)
9       n     data
9+n     1     data LRC   lrc(data)
```

`lrc(b) = (0x100 - sum(b)) & 0xFF`. Total length `10 + dataLen`.

`FrameParser.feed(Uint8List)` appends to an internal buffer and returns zero or more complete frames, resynchronising by scanning for `0x11 0xEF` and advancing **one byte** on an LRC mismatch.

Command constants:

```dart
abstract final class ChameleonCmd {
  static const int getAppVersion      = 1000;
  static const int changeDeviceMode   = 1001;
  static const int hf14aScan          = 2000;
  static const int mf1ReadOneBlock    = 2008;
  static const int mf1WriteOneBlock   = 2009;
  static const int hf14aRaw           = 2010;
}

abstract final class ChameleonStatus {
  static const int hfTagOk  = 0x00;
  static const int success  = 0x01;
  static const int mfErrAuth = 0x06;
  static const int parErr   = 0x60;
}
```

- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** — `git commit -m "feat(chameleon): framed protocol codec with resynchronising parser"`

---

### Task 7: `BleChameleonDevice`

**Files:**
- Modify: `pubspec.yaml` (add `flutter_reactive_ble`)
- Modify: `android/app/src/main/AndroidManifest.xml` (BLE permissions)
- Create: `lib/core/chameleon/ble_chameleon_device.dart`
- Test: `test/chameleon_command_encoding_test.dart`

**Interfaces:**
- Consumes: `ChameleonDevice`, the frame codec
- Produces: `BleChameleonDevice`

- [ ] **Step 1: Add the dependency and permissions**

`flutter_reactive_ble: ^5.5.0`. Manifest:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" tools:targetApi="s" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" tools:targetApi="s" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
```

`neverForLocation` is what keeps a location permission — and the appearance of tracking — out of the app.

Then confirm F-Droid's constraint still holds:

```bash
grep -rn "compileSdk" android/app/build.gradle   # MUST still read 34
flutter build apk --release && ls -l build/app/outputs/flutter-apk/app-release.apk
```

Record the APK size before and after this step in the commit message. **Measure it — do not estimate.**

- [ ] **Step 2: Write the failing encoding tests**

`BleChameleonDevice` cannot be unit-tested against real BLE, but the **command encoding and response parsing can**, and that is where the bugs live. Extract them as pure functions and test those.

```dart
test('mf1ReadOneBlock packs keyType, block, key', () {
  expect(encodeReadBlock(4, factoryKeyA),
      equals([0x60, 0x04, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]));
});

test('mf1WriteOneBlock appends the 16 data bytes', () {
  expect(encodeWriteBlock(4, factoryKeyA, Uint8List(16)).length, 24);
});

test('hf14aRaw packs options MSB-first, then timeout and bit length', () {
  // writeBitMSB: bit offset 0 is the MOST significant bit. autoSelect is
  // offset 3 (0x10) and appendCrc offset 2 (0x20).
  final b = encodeHf14aRaw(Uint8List.fromList([0x30, 0x04]),
      autoSelect: true, appendCrc: true, checkResponseCrc: true);
  expect(b[0], 0x20 | 0x10 | 0x04);
  expect(b.sublist(1, 3), equals([0x03, 0xE8]));  // timeout 1000
});

test('a full byte payload normalises to a bit length of 8 per byte', () {
  // dataBitLength = (len - 1) * 8 + ((bits + 7) % 8) + 1, so 0 maps to 8.
  final b = encodeHf14aRaw(Uint8List.fromList([0x26]), dataBitLength: 0);
  expect((b[3] << 8) | b[4], 8);
});

test('scanTag parses uidLen|uid|atqa|sak|atsLen|ats', () {
  final resp = Uint8List.fromList(
      [4, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x04, 0x08, 0]);
  final tag = parseScanResponse(resp)!;
  expect(tag.uid, equals([0xDE, 0xAD, 0xBE, 0xEF]));
  expect(tag.sak, 0x08);
});

test('an empty scan response means no tag, not an error', () {
  expect(parseScanResponse(Uint8List(0)), isNull);
});
```

- [ ] **Step 3: Run to verify failure**

- [ ] **Step 4: Implement**

BLE plumbing: connect to the Nordic UART Service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`, write commands to `6e400002-…`, subscribe to notifications on `6e400003-…` and feed them to `FrameParser`.

**`connect()` must send `CHANGE_DEVICE_MODE` → reader mode, and cache it.** The Chameleon boots into emulation mode and every HF command silently fails otherwise. This is invisible from the seam — the reference hides it inside each command's `assureDeviceMode` call — so it is done once at connect and asserted, rather than left to each call site to remember. Follow it with `GET_APP_VERSION` as a liveness check.

`readBlock`/`writeBlock` map `ChameleonStatus.mfErrAuth` to `CardAuthException`, never to a generic failure.

The DFU service `8ec90001-…` is never touched.

- [ ] **Step 5: Run to verify pass**
- [ ] **Step 6: Commit** — include the measured APK delta

---

## Phase 3 — The reader seam and UI

### Task 8: `CardReader` + `PhoneNfcReader`

**Files:**
- Create: `lib/features/nfc/domain/card_reader.dart`
- Create: `lib/features/nfc/data/phone_nfc_reader.dart`
- Modify: `lib/features/nfc/presentation/providers/nfc_provider.dart` (2 lines)
- Modify: `lib/main.dart` (1 line)
- Test: `test/card_reader_phone_delegation_test.dart`

**Interfaces:**
- Produces: `CardReader`, `PhoneNfcReader`, `activeReaderProvider`

**This task must change no behaviour.** There are only **four** `NfcRepository.instance` call sites, one of which is the declaration — so the swap is genuinely three lines of consumer code.

- [ ] **Step 1: Write `CardReader`**

Every member is copied from `NfcRepository`'s existing signatures — do not redesign them. Note the session starters are async **and return a stop closure**, *and* a separate `stopSession` exists; both are load-bearing.

```dart
abstract class CardReader {
  String get name;              // 'phone-nfc' | 'chameleon-ble'
  bool get supportsRawAccess;   // true only for Chameleon — gates the inspector
  bool get isInWriteCooldown;

  Future<void> connect();       // no-op for phone NFC
  Future<void> disconnect();    // no-op for phone NFC

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

- [ ] **Step 2: Write the delegation test**

```dart
test('PhoneNfcReader forwards every call to NfcRepository unchanged', () async {
  final r = PhoneNfcReader(NfcRepository.instance);
  expect(r.name, 'phone-nfc');
  expect(r.supportsRawAccess, isFalse);
  expect(await r.isAvailable(), equals(await NfcRepository.instance.isAvailable()));
});
```

- [ ] **Step 3: Implement `PhoneNfcReader`** as pure delegation. `connect`/`disconnect` are no-ops; `supportsRawAccess` is `false`.

- [ ] **Step 4: Add `activeReaderProvider`** in `nfc_provider.dart`, defaulting to `PhoneNfcReader`, and repoint the three consumer lines at it.

- [ ] **Step 5: Run the FULL suite**

`flutter analyze && flutter test` — every pre-existing test must pass untouched. That is the only evidence the extraction was safe.

- [ ] **Step 6: Commit** — `git commit -m "refactor(nfc): extract CardReader seam; phone path is pure delegation"`

---

### Task 9: `ChameleonReader`

**Files:**
- Create: `lib/features/nfc/data/chameleon_reader.dart`
- Test: `test/chameleon_reader_test.dart`

**Interfaces:**
- Consumes: `CardReader`, `ChameleonDevice`, `TagCodec`, `card_layout.dart`
- Produces: `ChameleonReader`

- [ ] **Step 1: Write the failing tests**

```dart
test('a read session polls until a card appears, then delivers a chunk', () async {
  final dev = FakeChameleonDevice.classic1k()..removeCard();
  final reader = ChameleonReader(dev, pollInterval: Duration.zero);
  Chunk? got;
  final stop = await reader.startReadSession(
    onChunkRead: (c, _) => got = c, onError: (_) {});
  dev.presentCardWith(validChunkBytes());
  await pumpUntil(() => got != null);
  stop();
  expect(got, isNotNull);
});

test('a foreign card raises CardAuthException and does NOT end the session', () async {
  // Auth failure means a hotel key on the reader, not a broken session.
  final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {1: Uint8List.fromList(const [9, 9, 9, 9, 9, 9])});
  final reader = ChameleonReader(dev, pollInterval: Duration.zero);
  var errors = 0;
  final stop = await reader.startReadSession(
      onChunkRead: (_, __) {}, onError: (_) => errors++);
  await pump();
  expect(reader.isSessionActive, isTrue, reason: 'a foreign card must not stop the session');
  stop();
});

test('the stop closure ends polling', () async {
  final reader = ChameleonReader(FakeChameleonDevice.classic1k(), pollInterval: Duration.zero);
  final stop = await reader.startReadSession(onChunkRead: (_, __) {}, onError: (_) {});
  stop();
  await pump();
  expect(reader.isSessionActive, isFalse);
});

test('a write is verified by reading back', () async {
  final dev = FakeChameleonDevice.classic1k()..corruptWrites();
  final reader = ChameleonReader(dev, pollInterval: Duration.zero);
  final r = await reader.writeTag(chunk: aChunk(), configuredTagType: NfcTagType.mifareClassic1k);
  expect(r, isA<NfcWriteError>());
});
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement**

A poll loop (default 300 ms, matching `chameleon-ble.ts`) calling `scanTag()` and firing the same callbacks reader-mode would. `supportsRawAccess` is `true`; `alertMessage` is accepted and ignored (it exists for iOS's NFC sheet).

Mifare read/write reuses `chunkToBlocks`, `firstBlockIsNfar`, `nfarTotalLength` from `lib/core/mifare/card_layout.dart` — already ported and fixture-verified, so do not reimplement them.

Port `readBlockStrict`: a response shorter than 16 bytes is a **marginal RF read**, raised as `CardReadException`, never treated as zero-padded content — otherwise a weak read reads as "this card holds no NFAR chunk".

Writes read back and compare, as `chameleon-ble.ts` does.

NTAG over Chameleon routes by SAK `0x00` and reuses `NdefFormatter.instance` (a private-constructor singleton — `.instance`, never `NdefFormatter()`).

- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** — `git commit -m "feat(nfc): Chameleon reader over the CardReader seam"`

---

### Task 10: Reader selection — state, permissions, device discovery

**Files:**
- Create: `lib/features/nfc/presentation/providers/reader_provider.dart`
- Create: `lib/features/nfc/data/ble_scanner.dart`
- Test: `test/reader_selection_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
test('switching readers disconnects the previous one first', () async {
  final c = ReaderController(...);
  await c.select(ReaderKind.chameleon, device: fakeDevice);
  await c.select(ReaderKind.phone);
  expect(fakeDevice.disconnectCalls, 1,
      reason: 'two readers must never hold radios at once');
});

test('a failed Chameleon connect falls back to a disconnected state, not a half-connected one', () async {
  final c = ReaderController(...);
  await expectLater(c.select(ReaderKind.chameleon, device: failingDevice), throwsA(anything));
  expect(c.state.isConnected, isFalse);
  expect(c.state.activeReader.name, 'phone-nfc');
});
```

The second test encodes the `failHandOff` lesson from the web app's `device.ts`: a connect that fails after teardown leaves the UI believing it is connected unless the failure path explicitly re-renders the disconnected state.

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** — `ReaderController` (a `StateNotifier`) owning the active `CardReader`, exclusivity, and teardown-before-connect. `BleScanner` wraps `flutter_reactive_ble`'s scan, filtered to devices advertising the Nordic UART service. Permissions via the existing `permission_handler`.
- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit**

---

### Task 11: Reader selection UI + localisation

**Files:**
- Create: `lib/features/nfc/presentation/screens/reader_picker_screen.dart`
- Modify: `lib/shared/widgets/home_screen.dart` (reader status + entry point)
- Modify: `lib/l10n/app_en.arb`, `app_ru.arb`, `app_tr.arb`, `app_uk.arb`, `app_ka.arb`, `app_pl.arb`, `app_be.arb`
- Test: `test/reader_picker_widget_test.dart`

- [ ] **Step 1: Add the strings to `app_en.arb`**

`readerPhoneNfc`, `readerChameleon`, `readerSelect`, `readerScanning`, `readerNoDevices`, `readerConnecting`, `readerConnected`, `readerDisconnect`, `readerBluetoothOff`, `readerPermissionDenied`, `inspectNeedsChameleon`.

- [ ] **Step 2: Translate into `app_ru`, `app_tr`, `app_uk`, `app_ka`, `app_pl`, `app_be`**, then `flutter gen-l10n`.

- [ ] **Step 3: Write the failing widget test** — the picker lists discovered devices, shows an empty state, and surfaces a permission denial rather than an empty list.

- [ ] **Step 4: Run to verify failure**
- [ ] **Step 5: Implement the screen** — reader choice, live BLE device list, connection state, Disconnect. Phone NFC hidden when the device has no NFC hardware; Chameleon offered whenever Bluetooth exists.
- [ ] **Step 6: Run `flutter analyze && flutter test`**
- [ ] **Step 7: Commit**

---

## Verification summary

| Gate | Command | Expected |
|---|---|---|
| Static analysis | `flutter analyze` | clean |
| All tests | `flutter test` | all pass, baseline never reduced |
| Phone path unchanged | existing tests, untouched | pass |
| Cross-language report | `test/inspect_hex_view_test.dart` | byte-identical to the TS fixture |
| F-Droid SDK floor | `grep compileSdk android/app/build.gradle` | `34` |
| APK cost | `flutter build apk --release`, before/after | measured and recorded, not estimated |

## Deliberately NOT in this plan

- The inspector **UI** (dialog, Copy/Share, its localisation) — sub-project C's remaining half
- iOS UI, entitlements or release work — the Dart layer stays platform-neutral, nothing more
- Chameleon emulation, slots, or DFU
- Any change to the NFAR format, on-tag bytes, or the archive/restore state machines

## Hardware validation (cannot be automated)

Nothing below is provable by any test in this plan, and none of it has ever been exercised from Dart:

1. A real Chameleon connects over BLE and accepts the reader-mode switch.
2. `HF14A_SCAN` returns a real UID and SAK.
3. Block read/write round-trips on a physical Mifare Classic card, and the read-back verification passes.
4. NTAG page reads work over `HF14A_RAW`, including the end-of-memory wrap the fake deliberately does not reproduce.
5. A foreign card surfaces as `CardAuthException` and does not end the session.
6. A full 64-block dump completes in a tolerable time — currently unknown, and deliberately not guessed at.
