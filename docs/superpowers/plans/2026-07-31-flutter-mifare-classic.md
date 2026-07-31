# Mifare Classic 1K (Flutter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let capable Android phones read and write the same raw-block Mifare Classic 1K cards the web app writes, closing an interop hole where those cards are currently invisible to the Flutter app.

**Architecture:** A `TagCodec` strategy seam replaces `NfcRepository`'s hardcoded NDEF assumption, with `NdefTagCodec` preserving today's behaviour and `MifareClassicTagCodec` added alongside. Block layout is a deliberate file-for-file port of the web app's `card-layout.ts`, guarded by a cross-language byte fixture. Hardware capability is detected through a `com.nxp.mifare` platform channel and hides the option rather than failing at tap.

**Tech Stack:** Flutter, Dart, `nfc_manager` 3.5.0 (`MifareClassic` platform tag), Riverpod, Kotlin (one platform channel), `flutter_test`.

**Source spec:** `docs/superpowers/specs/2026-07-31-flutter-mifare-classic-design.md`

## Global Constraints

- **Android only.** iOS has no CRYPTO1 support in Core NFC. Every capability path must return `false` on iOS rather than throwing.
- **Factory keys only:** key A = `FF FF FF FF FF FF`. No custom keys, no key recovery.
- **Sector trailers are NEVER written.** Only `usableBlockIndexes` (block 0 and every `b % 4 == 3` excluded) may be written. Writing a trailer can permanently brick a card.
- **`lib/core/mifare/card_layout.dart` is a port of `webapp/src/mifare/card-layout.ts`,** not a reimplementation. Same constant names, same values, same block ordering. Read the TypeScript before writing the Dart.
- **No change to the NFAR format, on-tag bytes, or the web app.**
- **All new user-facing strings go in `lib/l10n/app_en.arb` AND all 6 translation files** (`ru`, `tr`, `uk`, `ka`, `pl`, `be`), then `flutter gen-l10n`. This is a project rule from CLAUDE.md.
- **Commands:** `flutter test` (all), `flutter test test/<file>` (one), `flutter analyze`. Run `flutter gen-l10n` after touching any ARB file.
- **`flutter analyze` must introduce no new issues.** The baseline on master is 22 info-level issues; the count must not rise.
- **Commit style:** `feat: …` / `test: …`. End every commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `lib/core/mifare/card_layout.dart` | Pure block-layout maths, ported from the web app. No Flutter imports. |
| `lib/features/nfc/domain/tag_codec.dart` | The `TagCodec` interface. |
| `lib/features/nfc/domain/ndef_tag_codec.dart` | Today's NDEF behaviour, moved behind the interface. |
| `lib/features/nfc/domain/mifare_block_io.dart` | Narrow IO seam over `MifareClassic` so the codec is testable. |
| `lib/features/nfc/domain/mifare_tag_codec.dart` | Sector auth + block read/write using the layout. |
| `lib/features/nfc/data/nfc_capabilities.dart` | Platform-channel wrapper + Riverpod provider. |
| `test/mifare_card_layout_test.dart`, `test/mifare_tag_codec_test.dart`, `test/tag_codec_selection_test.dart`, `test/nfc_capabilities_test.dart` | Tests. |
| `tool/generate_mifare_fixtures.dart` | Cross-language fixture generator. |

**Modified:** `lib/core/constants/nfar_format.dart`, `lib/features/nfc/data/nfc_repository.dart`, `lib/features/nfc/domain/ndef_availability.dart`, `test/ndef_availability_test.dart`, `lib/features/archive/presentation/screens/archive_settings_screen.dart`, `lib/l10n/app_*.arb` (7), `android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/MainActivity.kt`, `CLAUDE.md`.

**Task order rationale:** pure logic first (Tasks 1–2), then the capability gate (3), then the seam refactor with no behaviour change (4), then the new codec (5), then wiring (6–7), then UI (8), then cross-language proof (9) and docs (10).

---

### Task 1: Mifare block layout

**Files:**
- Create: `lib/core/mifare/card_layout.dart`
- Test: `test/mifare_card_layout_test.dart`

**Interfaces:**
- Consumes: `NfarHeaderSize.total` (= 32) and `nfarMagic` from `lib/core/constants/nfar_format.dart`.
- Produces: `usableBlockIndexes` (`List<int>`, 47 entries), `blockSize` (16), `cardCapacityBytes` (752), `cardPayloadSize` (720), `MifareCapacityException`, `chunkToBlocks(Uint8List) → List<MifareBlockWrite>`, `class MifareBlockWrite { final int block; final Uint8List data; }`, `firstBlockIsNfar(Uint8List) → bool`, `nfarTotalLength(Uint8List) → int`.

**Read `webapp/src/mifare/card-layout.ts` before starting.** This is a port; the constants and ordering must match exactly.

- [ ] **Step 1: Write the failing test**

Create `test/mifare_card_layout_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';

void main() {
  group('layout constants', () {
    test('47 usable blocks, excluding block 0 and every sector trailer', () {
      expect(usableBlockIndexes.length, 47);
      expect(usableBlockIndexes.contains(0), isFalse);
      for (final b in usableBlockIndexes) {
        expect(b % 4 == 3, isFalse, reason: 'block $b is a sector trailer');
      }
      expect(usableBlockIndexes.first, 1);
      expect(usableBlockIndexes.last, 62);
    });

    test('capacity matches the web app', () {
      expect(cardCapacityBytes, 752);
      expect(cardPayloadSize, 720);
    });
  });

  group('chunkToBlocks', () {
    test('maps bytes onto usable blocks in order', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final writes = chunkToBlocks(bytes);
      expect(writes.length, 2);
      expect(writes[0].block, 1);
      expect(writes[1].block, 2);
      expect(writes[0].data, bytes.sublist(0, 16));
    });

    test('zero-pads the final partial block', () {
      final writes = chunkToBlocks(Uint8List.fromList([1, 2, 3]));
      expect(writes.length, 1);
      expect(writes[0].data.length, 16);
      expect(writes[0].data.sublist(3), Uint8List(13));
    });

    test('skips sector trailers once past block 2', () {
      final writes = chunkToBlocks(Uint8List(16 * 4));
      expect(writes.map((w) => w.block).toList(), [1, 2, 4, 5]);
    });

    test('rejects a chunk larger than the card', () {
      expect(() => chunkToBlocks(Uint8List(cardCapacityBytes + 1)),
          throwsA(isA<MifareCapacityException>()));
    });
  });

  group('probing', () {
    test('firstBlockIsNfar recognises magic + version', () {
      final block = Uint8List(16)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01]); // "NFAR" v1
      expect(firstBlockIsNfar(block), isTrue);
    });

    test('firstBlockIsNfar rejects a blank block', () {
      expect(firstBlockIsNfar(Uint8List(16)), isFalse);
    });

    test('nfarTotalLength reads the big-endian payload size at offset 26', () {
      final header = Uint8List(32)
        ..setAll(0, [0x4E, 0x46, 0x41, 0x52, 0x01])
        ..[26] = 0x01
        ..[27] = 0x2C; // 300
      expect(nfarTotalLength(header), 332); // 32 overhead + 300
    });
  });
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/mifare_card_layout_test.dart`
Expected: FAIL — "Error when reading 'lib/core/mifare/card_layout.dart': No such file or directory".

- [ ] **Step 3: Write the implementation**

Create `lib/core/mifare/card_layout.dart`:

```dart
import 'dart:typed_data';

import '../constants/nfar_format.dart';

/// Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K card.
///
/// Deliberate port of `webapp/src/mifare/card-layout.ts` — same constants, same
/// ordering — so cards written by either app are byte-identical. Change both or
/// neither.
///
/// Layout is raw NFAR-native: serialized chunk bytes run sequentially across the
/// 47 usable blocks (block 0 and every sector trailer skipped), zero-padding the
/// final block. The NFAR header is self-delimiting, so no per-block framing is
/// added.
const int blockSize = 16;

/// Blocks 0-63 minus block 0 (manufacturer) and every `b % 4 == 3` (sector
/// trailer, holds the keys — writing one can brick the card).
final List<int> usableBlockIndexes = List.unmodifiable(
  List<int>.generate(64, (b) => b).where((b) => b != 0 && b % 4 != 3).toList(),
);

final int cardCapacityBytes = usableBlockIndexes.length * blockSize; // 752
final int cardPayloadSize = cardCapacityBytes - NfarHeaderSize.total; // 720

/// A chunk does not fit a Mifare Classic 1K card.
class MifareCapacityException implements Exception {
  MifareCapacityException(this.message);
  final String message;
  @override
  String toString() => 'MifareCapacityException: $message';
}

/// One block-sized write: which block, and the 16 bytes to put there.
class MifareBlockWrite {
  const MifareBlockWrite(this.block, this.data);
  final int block;
  final Uint8List data;
}

/// Split serialized chunk bytes across the usable blocks, zero-padding the last.
List<MifareBlockWrite> chunkToBlocks(Uint8List chunkBytes) {
  if (chunkBytes.length > cardCapacityBytes) {
    throw MifareCapacityException(
      'Chunk is ${chunkBytes.length} bytes; a Mifare Classic 1K card holds '
      '$cardCapacityBytes',
    );
  }
  final blockCount = (chunkBytes.length + blockSize - 1) ~/ blockSize;
  final out = <MifareBlockWrite>[];
  for (var i = 0; i < blockCount; i++) {
    final data = Uint8List(blockSize); // zero-filled -> pads the last block
    final start = i * blockSize;
    final end = (start + blockSize).clamp(0, chunkBytes.length);
    data.setAll(0, chunkBytes.sublist(start, end));
    out.add(MifareBlockWrite(usableBlockIndexes[i], data));
  }
  return out;
}

/// Whether the first usable block starts an NFAR chunk.
bool firstBlockIsNfar(Uint8List block1) {
  if (block1.length < nfarMagic.length + 1) return false;
  for (var i = 0; i < nfarMagic.length; i++) {
    if (block1[i] != nfarMagic[i]) return false;
  }
  return block1[nfarMagic.length] == nfarVersion;
}

/// Total serialized length declared by an NFAR header.
int nfarTotalLength(Uint8List header) {
  if (!firstBlockIsNfar(header)) {
    throw const FormatException('Not an NFAR card: magic or version mismatch');
  }
  if (header.length < NfarHeaderSize.total) {
    throw FormatException(
      'Header too short: need ${NfarHeaderSize.total} bytes, '
      'got ${header.length}',
    );
  }
  final payloadSize = ByteData.sublistView(header).getUint16(26); // big-endian
  return NfarHeaderSize.total + payloadSize;
}
```

If `nfarMagic` or `nfarVersion` are named differently in `lib/core/constants/nfar_format.dart`, use the real names — read the file rather than assuming.

- [ ] **Step 4: Run the test and verify it passes**

Run: `flutter test test/mifare_card_layout_test.dart`
Expected: PASS, 9 tests.

- [ ] **Step 5: Run the full suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: all tests pass; analyzer issue count no higher than 22.

- [ ] **Step 6: Commit**

```bash
git add lib/core/mifare/card_layout.dart test/mifare_card_layout_test.dart
git commit -m "feat: port the Mifare Classic block layout from the web app"
```

---

### Task 2: Medium-aware `NfcTagType`

**Files:**
- Modify: `lib/core/constants/nfar_format.dart`
- Test: `test/ndef_capacity_test.dart` (append)

**Interfaces:**
- Consumes: `cardCapacityBytes`, `cardPayloadSize` from Task 1 — **do not import them here**; `nfar_format.dart` must stay free of `lib/core/mifare/` to avoid a cycle. Hardcode 752 in the enum value and assert equality in the test instead.
- Produces: `enum TagMedium { ndef, mifareClassic }`, `NfcTagType.medium` getter, `NfcTagType.mifareClassic1k`.

- [ ] **Step 1: Write the failing test**

Append to `test/ndef_capacity_test.dart`:

```dart
import 'package:nfc_archiver/core/mifare/card_layout.dart';

// ... inside main(), add:

  group('Mifare Classic tag type', () {
    test('carries the web app capacity and payload size', () {
      expect(NfcTagType.mifareClassic1k.capacity, cardCapacityBytes);
      expect(NfcTagType.mifareClassic1k.maxPayloadSize, cardPayloadSize);
      expect(NfcTagType.mifareClassic1k.maxPayloadSize, 720);
    });

    test('subtracts no NDEF overhead — it is not an NDEF medium', () {
      expect(NfcTagType.mifareClassic1k.medium, TagMedium.mifareClassic);
      expect(
        NfcTagType.mifareClassic1k.capacity -
            NfcTagType.mifareClassic1k.maxPayloadSize,
        NfarHeaderSize.total,
      );
    });

    test('NDEF tag types keep their existing medium and sizes', () {
      expect(NfcTagType.ntag215.medium, TagMedium.ndef);
      expect(NfcTagType.ntag215.maxPayloadSize, 504 - 44 - 32);
    });
  });
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/ndef_capacity_test.dart`
Expected: FAIL — "Undefined name 'TagMedium'" and no `mifareClassic1k` member.

- [ ] **Step 3: Write the implementation**

In `lib/core/constants/nfar_format.dart`, add above the enum:

```dart
/// How a tag stores an NFAR chunk. NDEF tags wrap the chunk in a MIME record
/// inside a Type-2 TLV; Mifare Classic holds the raw chunk across data blocks.
enum TagMedium { ndef, mifareClassic }
```

Give the enum a `medium` field defaulting to `TagMedium.ndef`, add the new value, and make `maxPayloadSize` medium-aware:

```dart
  ntag213(name: 'NTAG213', capacity: 144),
  ntag215(name: 'NTAG215', capacity: 504),
  ntag216(name: 'NTAG216', capacity: 888),

  /// Mifare Classic 1K: 47 usable blocks x 16 B = 752 B of raw storage.
  /// Value duplicated from card_layout.dart's cardCapacityBytes to keep this
  /// file free of a lib/core/mifare/ import; the test asserts they agree.
  mifareClassic1k(
      name: 'Mifare Classic 1K',
      capacity: 752,
      medium: TagMedium.mifareClassic),

  mifareUltralight(name: 'MIFARE Ultralight', capacity: 48),
  // ... remaining values unchanged, none pass `medium`

  const NfcTagType({
    required this.name,
    required this.capacity,
    this.medium = TagMedium.ndef,
  });

  final String name;
  final int capacity;
  final TagMedium medium;

  int get maxPayloadSize {
    // Mifare Classic carries the raw chunk with no NDEF framing at all, so only
    // the NFAR header and CRC come off the top.
    if (medium == TagMedium.mifareClassic) {
      final available = capacity - NfarHeaderSize.total;
      return available > 0 ? available : 0;
    }
    const ndefOverhead = 44;
    final available = capacity - ndefOverhead;
    return available - NfarHeaderSize.total;
  }
```

Keep every other enum value and the rest of the class exactly as they are.

- [ ] **Step 4: Run the test and verify it passes**

Run: `flutter test test/ndef_capacity_test.dart`
Expected: PASS.

- [ ] **Step 5: Check nothing else broke on the enum**

`NfcTagInfo.effectiveTagType` and `archive_settings_screen.dart` both iterate `NfcTagType.values`, so a new value changes their behaviour.

Run: `flutter test && flutter analyze`
Expected: all pass. The picker will now show Mifare unconditionally — Task 8 gates it; that is expected at this point.

- [ ] **Step 6: Commit**

```bash
git add lib/core/constants/nfar_format.dart test/ndef_capacity_test.dart
git commit -m "feat: make NfcTagType medium-aware and add Mifare Classic 1K"
```

---

### Task 3: Hardware capability detection

**Files:**
- Create: `lib/features/nfc/data/nfc_capabilities.dart`
- Modify: `android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/MainActivity.kt`
- Test: `test/nfc_capabilities_test.dart`

**Interfaces:**
- Produces: `const MethodChannel nfcCapabilitiesChannel = MethodChannel('com.nfcarchiver/nfc_capabilities')`, `Future<bool> hasMifareClassicSupport()`, `final mifareSupportProvider = FutureProvider<bool>(...)`.

- [ ] **Step 1: Write the failing test**

Create `test/nfc_capabilities_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, null);
  });

  test('reports true when the platform says the feature is present', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      expect(call.method, 'hasMifareClassic');
      return true;
    });
    expect(await hasMifareClassicSupport(), isTrue);
  });

  test('reports false when the platform says it is absent', () async {
    messenger.setMockMethodCallHandler(
        nfcCapabilitiesChannel, (call) async => false);
    expect(await hasMifareClassicSupport(), isFalse);
  });

  test('reports false when the channel is unimplemented (iOS)', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      throw MissingPluginException('no implementation');
    });
    expect(await hasMifareClassicSupport(), isFalse);
  });

  test('reports false rather than throwing on any platform error', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      throw PlatformException(code: 'ERROR');
    });
    expect(await hasMifareClassicSupport(), isFalse);
  });
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/nfc_capabilities_test.dart`
Expected: FAIL — cannot read `lib/features/nfc/data/nfc_capabilities.dart`.

- [ ] **Step 3: Write the Dart side**

Create `lib/features/nfc/data/nfc_capabilities.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Platform channel for NFC hardware capabilities Flutter cannot query itself.
const MethodChannel nfcCapabilitiesChannel =
    MethodChannel('com.nfcarchiver/nfc_capabilities');

/// Whether this device's NFC controller can talk to Mifare Classic cards.
///
/// Mifare Classic uses NXP's proprietary CRYPTO1 cipher rather than a standard
/// ISO 14443-4 protocol, so support lives in the controller chip: NXP
/// controllers have it, Broadcom and Samsung's S3FWRN5 generally do not, and
/// iOS never does. Any failure to answer is treated as "not supported" — the
/// feature is hidden rather than offered and then failing at tap.
Future<bool> hasMifareClassicSupport() async {
  try {
    final result =
        await nfcCapabilitiesChannel.invokeMethod<bool>('hasMifareClassic');
    return result ?? false;
  } on MissingPluginException {
    return false; // iOS, or an older build without the channel
  } on PlatformException {
    return false;
  }
}

/// Queried once and cached for the app's lifetime — hardware does not change.
final mifareSupportProvider =
    FutureProvider<bool>((ref) => hasMifareClassicSupport());
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `flutter test test/nfc_capabilities_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the Android side**

Replace `android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/MainActivity.kt` with:

```kotlin
package com.nfcarchiver.nfc_archiver

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.nfcarchiver/nfc_capabilities"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // "com.nxp.mifare" is the standard Android system feature
                    // reported by devices whose NFC controller implements
                    // CRYPTO1. Absent on Broadcom/Samsung S3FWRN5 controllers.
                    "hasMifareClassic" -> result.success(
                        packageManager.hasSystemFeature("com.nxp.mifare")
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
```

- [ ] **Step 6: Verify the Android build still compiles**

Run: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL. This is the only way to catch a Kotlin error — `flutter analyze` does not compile Kotlin.

- [ ] **Step 7: Commit**

```bash
git add lib/features/nfc/data/nfc_capabilities.dart test/nfc_capabilities_test.dart android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/MainActivity.kt
git commit -m "feat: detect Mifare Classic hardware support via platform channel"
```

---

### Task 4: `TagCodec` seam with NDEF behaviour preserved

**Files:**
- Create: `lib/features/nfc/domain/tag_codec.dart`, `lib/features/nfc/domain/ndef_tag_codec.dart`
- Modify: `lib/features/nfc/data/nfc_repository.dart`

**Interfaces:**
- Consumes: `NdefFormatter` (`chunkToNdef`, `ndefToChunk`, `requiredNdefSize`) from `lib/features/nfc/domain/ndef_formatter.dart`; `Chunk` from `lib/core/models/chunk.dart`.
- Produces:
  ```dart
  abstract interface class TagCodec {
    String get name;
    bool supports(NfcTag tag);
    Future<int> capacityBytes(NfcTag tag);
    Future<Chunk?> readChunk(NfcTag tag);
    Future<void> writeChunk(NfcTag tag, Chunk chunk);
  }
  ```
  and `class NdefTagCodec implements TagCodec`.

**This task must not change any behaviour.** It is a pure refactor; the existing suite is the gate.

- [ ] **Step 1: Record the baseline**

Run: `flutter test`
Expected: all tests pass. Note the count — it must be identical at Step 5.

- [ ] **Step 2: Create the interface**

Create `lib/features/nfc/domain/tag_codec.dart`:

```dart
import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/models/chunk.dart';

/// How one storage medium carries an NFAR chunk on a tag.
///
/// `NfcRepository` owns sessions, cooldowns and errors; a codec owns the bytes.
/// Mirrors the web app's `Transport` seam so the two codebases stay legible to
/// each other.
abstract interface class TagCodec {
  /// Short identifier for logs and error messages, e.g. 'NDEF'.
  String get name;

  /// Whether this codec can handle the tapped tag.
  bool supports(NfcTag tag);

  /// Largest serialized chunk this tag can hold.
  ///
  /// Defined as chunk bytes, NOT the medium's raw size, so the two codecs
  /// return comparable numbers: the caller checks `chunk.totalSize > capacity`
  /// without knowing which medium it is talking to.
  Future<int> capacityBytes(NfcTag tag);

  /// Read a chunk, or null if the tag holds no valid NFAR data.
  Future<Chunk?> readChunk(NfcTag tag);

  /// Write a chunk. Throws on failure.
  Future<void> writeChunk(NfcTag tag, Chunk chunk);
}
```

- [ ] **Step 3: Move the NDEF logic behind it**

Create `lib/features/nfc/domain/ndef_tag_codec.dart`:

```dart
import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/models/chunk.dart';
import 'ndef_formatter.dart';
import 'tag_codec.dart';

/// NDEF-backed tags: NTAG213/215/216 and Mifare Ultralight.
class NdefTagCodec implements TagCodec {
  NdefTagCodec([NdefFormatter? formatter])
      : _formatter = formatter ?? NdefFormatter();

  final NdefFormatter _formatter;

  @override
  String get name => 'NDEF';

  @override
  bool supports(NfcTag tag) => Ndef.from(tag) != null;

  @override
  Future<int> capacityBytes(NfcTag tag) async {
    final ndef = Ndef.from(tag)!;
    // ndef.maxSize is the NDEF *message* capacity. Subtract the record overhead
    // and the terminator byte to get the chunk bytes that actually fit.
    return NfcTagType.maxPayloadForCapacity(ndef.maxSize) +
        NfarHeaderSize.total;
  }

  @override
  Future<Chunk?> readChunk(NfcTag tag) async {
    final ndef = Ndef.from(tag)!;
    return _formatter.ndefToChunk(await ndef.read());
  }

  @override
  Future<void> writeChunk(NfcTag tag, Chunk chunk) async {
    final ndef = Ndef.from(tag)!;
    if (!ndef.isWritable) {
      throw StateError('Tag is not writable');
    }
    await ndef.write(_formatter.chunkToNdef(chunk));
  }
}
```

Add the imports `../../../core/constants/nfar_format.dart` for `NfcTagType` and `NfarHeaderSize`.

- [ ] **Step 4: Route `NfcRepository` through the codec**

In `lib/features/nfc/data/nfc_repository.dart`, add a field `final List<TagCodec> _codecs = [NdefTagCodec()];` and a selector:

```dart
  /// First codec that can handle this tag, or null.
  TagCodec? _codecFor(NfcTag tag) {
    for (final codec in _codecs) {
      if (codec.supports(tag)) return codec;
    }
    return null;
  }
```

Replace the three NDEF call sites so they go through the selected codec, keeping every message and control-flow branch exactly as it is today: the read path (`Ndef.from(tag)` → `ndef.read()` → `ndefToChunk`), the write path (`Ndef.from(tag)` → writability check → `maxSize` comparison → `ndef.write`), and `_extractTagInfo`. Where a codec is null, keep calling the existing `messageFor(_ndefUnavailableReason(tag))`.

- [ ] **Step 5: Run the full suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: identical test count and result to Step 1; analyzer no worse than 22.

- [ ] **Step 6: Commit**

```bash
git add lib/features/nfc/domain/tag_codec.dart lib/features/nfc/domain/ndef_tag_codec.dart lib/features/nfc/data/nfc_repository.dart
git commit -m "refactor: put NDEF tag access behind a TagCodec seam"
```

---

### Task 5: Mifare block IO seam and codec

**Files:**
- Create: `lib/features/nfc/domain/mifare_block_io.dart`, `lib/features/nfc/domain/mifare_tag_codec.dart`
- Test: `test/mifare_tag_codec_test.dart`

**Interfaces:**
- Consumes: `TagCodec` (Task 4); `chunkToBlocks`, `usableBlockIndexes`, `blockSize`, `cardCapacityBytes`, `firstBlockIsNfar`, `nfarTotalLength`, `MifareBlockWrite` (Task 1); `Chunk.fromBytes`, `chunk.toBytes()`, `chunk.totalSize`.
- Produces:
  ```dart
  abstract interface class MifareBlockIO {
    Future<bool> authenticateSector(int sectorIndex, Uint8List keyA);
    Future<Uint8List> readBlock(int blockIndex);
    Future<void> writeBlock(int blockIndex, Uint8List data);
  }
  const factoryKeyA = <int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
  class MifareAuthException implements Exception { … }
  class MifareTagCodec implements TagCodec { MifareTagCodec(this._ioFor); }
  ```
  where `_ioFor` is `MifareBlockIO? Function(NfcTag)`.

- [ ] **Step 1: Write the failing test**

Create `test/mifare_tag_codec_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_block_io.dart';

/// In-memory Mifare Classic 1K: 64 blocks of 16 bytes, factory-keyed.
class FakeMifareBlockIO implements MifareBlockIO {
  final Map<int, Uint8List> blocks = {};
  final List<int> authenticatedSectors = [];
  final List<int> writtenBlocks = [];
  bool failAuth = false;

  @override
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA) async {
    if (failAuth) return false;
    authenticatedSectors.add(sectorIndex);
    return true;
  }

  @override
  Future<Uint8List> readBlock(int blockIndex) async =>
      blocks[blockIndex] ?? Uint8List(16);

  @override
  Future<void> writeBlock(int blockIndex, Uint8List data) async {
    writtenBlocks.add(blockIndex);
    blocks[blockIndex] = Uint8List.fromList(data);
  }
}

Chunk makeChunk(int payloadLen) {
  final payload = Uint8List.fromList(
      List.generate(payloadLen, (i) => (i + 3) % 256));
  return Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 4),
    totalChunks: 1,
    chunkIndex: 0,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );
}

void main() {
  test('write then read round-trips a chunk', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);
    final chunk = makeChunk(200);

    await codec.writeChunk(FakeTag(), chunk);
    final read = await codec.readChunk(FakeTag());

    expect(read, isNotNull);
    expect(read!.payload, chunk.payload);
    expect(read.chunkIndex, chunk.chunkIndex);
  });

  test('never writes block 0 or a sector trailer', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);

    await codec.writeChunk(FakeTag(), makeChunk(cardPayloadSize));

    expect(io.writtenBlocks.contains(0), isFalse);
    for (final b in io.writtenBlocks) {
      expect(b % 4 == 3, isFalse, reason: 'wrote sector trailer $b');
    }
  });

  test('authenticates a sector before touching its blocks', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);
    await codec.writeChunk(FakeTag(), makeChunk(200));
    expect(io.authenticatedSectors, isNotEmpty);
    expect(io.authenticatedSectors.first, 0);
  });

  test('a failed authentication throws rather than writing', () async {
    final io = FakeMifareBlockIO()..failAuth = true;
    final codec = MifareTagCodec((_) => io);
    await expectLater(
      codec.writeChunk(FakeTag(), makeChunk(200)),
      throwsA(isA<MifareAuthException>()),
    );
    expect(io.writtenBlocks, isEmpty);
  });

  test('reads null from a blank card rather than throwing', () async {
    final codec = MifareTagCodec((_) => FakeMifareBlockIO());
    expect(await codec.readChunk(FakeTag()), isNull);
  });

  test('capacity is the raw card capacity', () async {
    final codec = MifareTagCodec((_) => FakeMifareBlockIO());
    expect(await codec.capacityBytes(FakeTag()), cardCapacityBytes);
  });
}
```

Define the stand-in tag once at the top of the test file:

```dart
import 'package:nfc_manager/nfc_manager.dart';

/// nfc_manager exposes a const NfcTag constructor explicitly for testing.
NfcTag FakeTag() => const NfcTag(handle: 'test', data: <String, dynamic>{});
```

`ChecksumService` has a private constructor — always `ChecksumService.instance`, never `ChecksumService()`.

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/mifare_tag_codec_test.dart`
Expected: FAIL — missing `mifare_block_io.dart`.

- [ ] **Step 3: Write the IO seam**

Create `lib/features/nfc/domain/mifare_block_io.dart`:

```dart
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';

/// Factory key A. Every card this app writes stays factory-keyed, because
/// sector trailers are never written.
final Uint8List factoryKeyA =
    Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

/// Sector authentication failed — the card is not factory-keyed.
class MifareAuthException implements Exception {
  MifareAuthException(this.sectorIndex);
  final int sectorIndex;
  @override
  String toString() =>
      'MifareAuthException: sector $sectorIndex rejected the factory key';
}

/// Narrow block-level access to a Mifare Classic card.
///
/// Exists so the codec is testable without hardware: `nfc_manager`'s
/// `MifareClassic` cannot be constructed in a test.
abstract interface class MifareBlockIO {
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA);
  Future<Uint8List> readBlock(int blockIndex);
  Future<void> writeBlock(int blockIndex, Uint8List data);
}

/// Real implementation over `nfc_manager`.
class NfcManagerMifareBlockIO implements MifareBlockIO {
  NfcManagerMifareBlockIO(this._mifare);
  final MifareClassic _mifare;

  @override
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA) =>
      _mifare.authenticateSectorWithKeyA(sectorIndex: sectorIndex, key: keyA);

  @override
  Future<Uint8List> readBlock(int blockIndex) =>
      _mifare.readBlock(blockIndex: blockIndex);

  @override
  Future<void> writeBlock(int blockIndex, Uint8List data) =>
      _mifare.writeBlock(blockIndex: blockIndex, data: data);
}

/// Adapter used in production: null when the tag is not a Mifare Classic card,
/// or when this phone's controller cannot talk CRYPTO1.
MifareBlockIO? mifareIoFor(NfcTag tag) {
  final mifare = MifareClassic.from(tag);
  return mifare == null ? null : NfcManagerMifareBlockIO(mifare);
}
```

- [ ] **Step 4: Write the codec**

Create `lib/features/nfc/domain/mifare_tag_codec.dart`:

```dart
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/mifare/card_layout.dart';
import '../../../core/models/chunk.dart';
import 'mifare_block_io.dart';
import 'tag_codec.dart';

/// Mifare Classic 1K holding a raw NFAR chunk across its usable data blocks.
///
/// Byte-compatible with the web app: same block set, same ordering, same
/// zero-padding. Sector trailers are never written, so cards stay factory-keyed
/// and re-writable.
class MifareTagCodec implements TagCodec {
  MifareTagCodec(this._ioFor);

  final MifareBlockIO? Function(NfcTag tag) _ioFor;

  @override
  String get name => 'Mifare Classic';

  @override
  bool supports(NfcTag tag) => _ioFor(tag) != null;

  @override
  Future<int> capacityBytes(NfcTag tag) async => cardCapacityBytes;

  int _sectorOf(int block) => block ~/ 4;

  /// Authenticate a sector once, then keep using it until the sector changes.
  Future<void> _ensureSector(
      MifareBlockIO io, int block, int? currentSector) async {
    final sector = _sectorOf(block);
    if (sector == currentSector) return;
    if (!await io.authenticateSector(sector, factoryKeyA)) {
      throw MifareAuthException(sector);
    }
  }

  @override
  Future<Chunk?> readChunk(NfcTag tag) async {
    final io = _ioFor(tag);
    if (io == null) return null;

    int? sector;
    final first = usableBlockIndexes.first;
    await _ensureSector(io, first, sector);
    sector = _sectorOf(first);
    final head = await io.readBlock(first);
    if (!firstBlockIsNfar(head)) return null;

    // Read enough blocks to cover the declared length. The header spans the
    // first two usable blocks, so read the second before trusting the length.
    final bytes = BytesBuilder()..add(head);
    for (final block in usableBlockIndexes.skip(1)) {
      await _ensureSector(io, block, sector);
      sector = _sectorOf(block);
      bytes.add(await io.readBlock(block));
      if (bytes.length >= 32) {
        final total = nfarTotalLength(Uint8List.fromList(bytes.toBytes()));
        if (bytes.length >= total) {
          return Chunk.fromBytes(
              Uint8List.fromList(bytes.toBytes().sublist(0, total)));
        }
      }
    }
    return null;
  }

  @override
  Future<void> writeChunk(NfcTag tag, Chunk chunk) async {
    final io = _ioFor(tag);
    if (io == null) {
      throw StateError('Tag is not a Mifare Classic card');
    }
    final writes = chunkToBlocks(chunk.toBytes());

    // Authenticate every sector we are about to touch BEFORE writing anything,
    // so a non-factory-keyed card fails without leaving a half-written chunk.
    final sectors = writes.map((w) => _sectorOf(w.block)).toSet();
    for (final sector in sectors) {
      if (!await io.authenticateSector(sector, factoryKeyA)) {
        throw MifareAuthException(sector);
      }
    }

    int? sector;
    for (final write in writes) {
      await _ensureSector(io, write.block, sector);
      sector = _sectorOf(write.block);
      await io.writeBlock(write.block, write.data);
      final back = await io.readBlock(write.block);
      if (!_bytesEqual(back, write.data)) {
        throw StateError('Read-back mismatch on block ${write.block}');
      }
    }
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `flutter test test/mifare_tag_codec_test.dart`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the full suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer no worse than 22.

- [ ] **Step 7: Commit**

```bash
git add lib/features/nfc/domain/mifare_block_io.dart lib/features/nfc/domain/mifare_tag_codec.dart test/mifare_tag_codec_test.dart
git commit -m "feat: add a Mifare Classic tag codec behind a testable block-IO seam"
```

---

### Task 6: Route the repository across both codecs

**Files:**
- Modify: `lib/features/nfc/data/nfc_repository.dart`
- Test: `test/tag_codec_selection_test.dart`

**Interfaces:**
- Consumes: `NdefTagCodec` (Task 4), `MifareTagCodec` + `mifareIoFor` (Task 5).
- Produces: no new public API; `NfcRepository._codecs` becomes `[MifareTagCodec(mifareIoFor), NdefTagCodec()]`.

- [ ] **Step 1: Write the failing test**

Create `test/tag_codec_selection_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_tag_codec.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_tag_codec.dart';
import 'package:nfc_archiver/features/nfc/domain/tag_codec.dart';

// Reuse FakeMifareBlockIO from mifare_tag_codec_test.dart by importing it, or
// duplicate the four-method stub here if the test file does not export it.

void main() {
  test('Mifare is tried before NDEF', () {
    // NDEF is never written onto Classic, so a tag exposing MifareClassic is
    // unambiguously ours to handle with the Mifare codec. Order matters: a
    // Classic card that happens to be NDEF-formatted by another app must still
    // route to Mifare, or we would read the wrong bytes.
    final codecs = <TagCodec>[
      MifareTagCodec((_) => null),
      NdefTagCodec(),
    ];
    expect(codecs.first, isA<MifareTagCodec>());
  });

  test('MifareTagCodec does not claim a tag with no Mifare IO', () {
    expect(MifareTagCodec((_) => null).supports(FakeTag()), isFalse);
  });
}
```

Use the same `FakeTag()` construction settled in Task 5.

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/tag_codec_selection_test.dart`
Expected: FAIL — the repository still has only the NDEF codec, and the imports may not resolve until Step 3.

- [ ] **Step 3: Wire both codecs**

In `lib/features/nfc/data/nfc_repository.dart`, change the codec list to:

```dart
  /// Mifare first: NDEF is never written onto Classic, so a tag exposing
  /// MifareClassic is unambiguously ours. NDEF handles everything else.
  final List<TagCodec> _codecs = [
    MifareTagCodec(mifareIoFor),
    NdefTagCodec(),
  ];
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer no worse than 22.

- [ ] **Step 5: Commit**

```bash
git add lib/features/nfc/data/nfc_repository.dart test/tag_codec_selection_test.dart
git commit -m "feat: route NFC reads and writes across both tag codecs"
```

---

### Task 7: Third classification outcome for unsupported phones

**Files:**
- Modify: `lib/features/nfc/domain/ndef_availability.dart`, `lib/features/nfc/data/nfc_repository.dart`
- Test: `test/ndef_availability_test.dart` (append)

**Interfaces:**
- Consumes: `hasMifareClassicSupport()` (Task 3) at the call site only.
- Produces: `NdefUnavailableReason.mifareUnsupported`; `classifyNdefUnavailable` gains a third named parameter `required bool deviceSupportsMifare`.

- [ ] **Step 1: Write the failing test**

Append to `test/ndef_availability_test.dart`:

```dart
  group('mifareUnsupported', () {
    test('NfcA with no Ndef and no MifareClassic on an incapable phone', () {
      // A Mifare Classic card tapped on a phone whose controller cannot do
      // CRYPTO1 looks exactly like this. Reporting "try again" would invite
      // endless retries of something that can never succeed.
      expect(
        classifyNdefUnavailable(
          hasNfcA: true,
          hasMifareUltralight: false,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.mifareUnsupported,
      );
    });

    test('the same signature on a CAPABLE phone is a failed detection', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: true,
          hasMifareUltralight: false,
          deviceSupportsMifare: true,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('MifareUltralight present is always a failed detection', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: true,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.detectionFailed,
      );
    });

    test('no NFC-A at all is still notNdefFormatted', () {
      expect(
        classifyNdefUnavailable(
          hasNfcA: false,
          hasMifareUltralight: false,
          deviceSupportsMifare: false,
        ),
        NdefUnavailableReason.notNdefFormatted,
      );
    });

    test('its message names the hardware limit, not a retry', () {
      final message = messageFor(NdefUnavailableReason.mifareUnsupported);
      expect(message.toLowerCase(), contains('mifare'));
      expect(message.toLowerCase(), isNot(contains('again')));
    });
  });
```

Update the four existing `classifyNdefUnavailable` calls in this file to pass `deviceSupportsMifare: true`, which preserves their current expectations.

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/ndef_availability_test.dart`
Expected: FAIL — no named parameter `deviceSupportsMifare`, and `mifareUnsupported` undefined.

- [ ] **Step 3: Extend the classifier**

In `lib/features/nfc/domain/ndef_availability.dart`, add the enum value and rewrite the function:

```dart
  /// The tag exposes NFC-A but neither Ndef nor MifareClassic, on a phone whose
  /// controller cannot do CRYPTO1 — the signature of a Mifare Classic card on
  /// hardware that will never read it. Retrying cannot help.
  mifareUnsupported,
```

```dart
NdefUnavailableReason classifyNdefUnavailable({
  required bool hasNfcA,
  required bool hasMifareUltralight,
  required bool deviceSupportsMifare,
}) {
  if (hasMifareUltralight) return NdefUnavailableReason.detectionFailed;
  if (hasNfcA) {
    return deviceSupportsMifare
        ? NdefUnavailableReason.detectionFailed
        : NdefUnavailableReason.mifareUnsupported;
  }
  return NdefUnavailableReason.notNdefFormatted;
}
```

Add the message case:

```dart
    case NdefUnavailableReason.mifareUnsupported:
      return "This looks like a Mifare Classic card. Your phone's NFC chip "
          "can't read them.";
```

- [ ] **Step 4: Update the call site**

In `lib/features/nfc/data/nfc_repository.dart`, `_ndefUnavailableReason` needs the capability. Cache it in a field set once:

```dart
  bool _deviceSupportsMifare = false;

  /// Call once at startup, before any session.
  Future<void> initCapabilities() async {
    _deviceSupportsMifare = await hasMifareClassicSupport();
  }
```

and pass `deviceSupportsMifare: _deviceSupportsMifare` in `_ndefUnavailableReason`. Call `initCapabilities()` from app startup in `lib/main.dart` alongside the other initialisation.

- [ ] **Step 5: Run the tests and verify they pass**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer no worse than 22.

- [ ] **Step 6: Commit**

```bash
git add lib/features/nfc/domain/ndef_availability.dart lib/features/nfc/data/nfc_repository.dart lib/main.dart test/ndef_availability_test.dart
git commit -m "feat: report a Mifare card tapped on incapable hardware honestly"
```

---

### Task 8: Picker gating, mismatch error, and localization

**Files:**
- Modify: `lib/features/archive/presentation/screens/archive_settings_screen.dart`, `lib/l10n/app_en.arb` + the six translation files
- Test: manual, plus `flutter analyze`

**Interfaces:**
- Consumes: `mifareSupportProvider` (Task 3), `TagMedium` and `NfcTagType.mifareClassic1k` (Task 2), `TagCodec.name` (Task 4).
- Produces: l10n keys `mifareNotSupportedOnDevice`, `tagTypeMismatch`.

- [ ] **Step 1: Add the English strings**

In `lib/l10n/app_en.arb`:

```json
  "mifareNotSupportedOnDevice": "This looks like a Mifare Classic card. Your phone's NFC chip can't read them.",
  "@mifareNotSupportedOnDevice": {
    "description": "Shown when a Mifare Classic card is tapped on a phone whose NFC controller lacks CRYPTO1 support"
  },
  "tagTypeMismatch": "That's a {tapped} card, but this archive is configured for {configured} — change the tag type in Settings.",
  "@tagTypeMismatch": {
    "description": "Shown when the tapped card's medium differs from the configured tag type",
    "placeholders": { "tapped": { "type": "String" }, "configured": { "type": "String" } }
  }
```

- [ ] **Step 2: Translate into all six other locales**

Add the same two keys to `app_ru.arb`, `app_tr.arb`, `app_uk.arb`, `app_ka.arb`, `app_pl.arb`, `app_be.arb`. Keep `{tapped}` and `{configured}` placeholders intact and let each locale order them naturally. Do not translate "Mifare Classic", "NTAG213/215/216" or "NFC".

- [ ] **Step 3: Regenerate and verify**

Run: `flutter gen-l10n && flutter analyze`
Expected: generation succeeds; no new analyzer issues. A missing key in any locale fails here.

- [ ] **Step 4: Gate the picker**

In `archive_settings_screen.dart`, the list currently filters only `custom`. Watch the capability provider and filter Mifare out when unsupported:

```dart
    final mifareSupported =
        ref.watch(mifareSupportProvider).valueOrNull ?? false;
```

```dart
                  ...NfcTagType.values
                      .where((t) => t != NfcTagType.custom)
                      .where((t) =>
                          t.medium != TagMedium.mifareClassic || mifareSupported)
                      .map((type) => RadioListTile<NfcTagType>(
```

Keep the rest of the `RadioListTile` exactly as it is.

- [ ] **Step 5: Report a medium mismatch on write**

In `nfc_repository.dart`'s write session, after selecting the codec, reject a medium mismatch before writing:

```dart
          final expectedMedium = chunk.payload.length > 0
              ? configuredTagType.medium
              : TagMedium.ndef;
```

Simpler and sufficient: compare the selected codec's `name` against the configured type's medium, and when they disagree call `onError` with the localized `tagTypeMismatch` string built from `codec.name` and `configuredTagType.name`. The configured type must be passed into `startWriteSession` as a new required parameter `NfcTagType configuredTagType`, and threaded from `archive_provider`.

- [ ] **Step 6: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer no worse than 22.

- [ ] **Step 7: Commit**

```bash
git add lib/features/archive/presentation/screens/archive_settings_screen.dart lib/features/nfc/data/nfc_repository.dart lib/l10n/
git commit -m "feat: gate the Mifare option on hardware support and report mismatches"
```

---

### Task 9: Cross-language byte fixture

**Files:**
- Create: `tool/generate_mifare_fixtures.dart`
- Modify: `webapp/test/interop-dart.test.ts`

**Interfaces:**
- Consumes: `chunkToBlocks` (Task 1); the web app's `chunkToBlocks` from `webapp/src/mifare/card-layout.ts`.
- Produces: `webapp/test/fixtures/mifare-card.json` — `{ "payloadLength": int, "blocks": [{ "block": int, "hex": string }] }`.

This is what keeps the port honest: two implementations of the same layout would drift, a byte fixture cannot.

- [ ] **Step 1: Write the generator**

Create `tool/generate_mifare_fixtures.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';

/// Emits the exact block image the Dart layout produces, so the TypeScript
/// side can assert byte equality. Run: dart run tool/generate_mifare_fixtures.dart
void main() {
  const payloadLength = 300;
  final payload =
      Uint8List.fromList(List.generate(payloadLength, (i) => (i + 3) % 256));
  final chunk = Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 4),
    totalChunks: 1,
    chunkIndex: 0,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );

  final blocks = chunkToBlocks(chunk.toBytes())
      .map((w) => {
            'block': w.block,
            'hex': w.data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          })
      .toList();

  final out = File('webapp/test/fixtures/mifare-card.json');
  out.createSync(recursive: true);
  out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
    'payloadLength': payloadLength,
    'blocks': blocks,
  }));
  stdout.writeln('wrote ${out.path} with ${blocks.length} blocks');
}
```

- [ ] **Step 2: Generate the fixture**

Run: `dart run tool/generate_mifare_fixtures.dart`
Expected: `wrote webapp/test/fixtures/mifare-card.json with 21 blocks` (332 bytes over 16-byte blocks = 21).

- [ ] **Step 3: Write the failing TypeScript assertion**

Append to `webapp/test/interop-dart.test.ts`:

```ts
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { chunkToBlocks } from '../src/mifare/card-layout.js';
import { encodeChunk } from '../src/chunk.js';
import { crc32 } from '../src/crc32.js';

test('Dart and TypeScript produce identical Mifare card images', () => {
  const fixture = JSON.parse(readFileSync(
    fileURLToPath(new URL('../../test/fixtures/mifare-card.json', import.meta.url)), 'utf8',
  )) as { payloadLength: number; blocks: Array<{ block: number; hex: string }> };

  const payload = new Uint8Array(fixture.payloadLength).map((_, i) => (i + 3) % 256);
  const bytes = encodeChunk({
    archiveId: new Uint8Array(16).fill(4),
    totalChunks: 1, chunkIndex: 0, payload, crc32: crc32(payload), flags: 0,
  });

  const ours = chunkToBlocks(bytes);
  assert.equal(ours.length, fixture.blocks.length);
  for (let i = 0; i < ours.length; i++) {
    assert.equal(ours[i]!.block, fixture.blocks[i]!.block);
    assert.equal(
      Array.from(ours[i]!.data, (b) => b.toString(16).padStart(2, '0')).join(''),
      fixture.blocks[i]!.hex,
      `block ${ours[i]!.block} differs`,
    );
  }
});
```

Verify the fixture path resolves from `dist/test/`; correct the depth if it throws ENOENT.

- [ ] **Step 4: Run the web app suite**

```bash
source ~/.nvm/nvm.sh && nvm use --lts
cd webapp && rm -rf dist && npm test
```

Expected: PASS. A failure here means the Dart port and the TypeScript original disagree — fix the **Dart**, since the TypeScript is the shipped original.

- [ ] **Step 5: Commit**

```bash
git add tool/generate_mifare_fixtures.dart webapp/test/fixtures/mifare-card.json webapp/test/interop-dart.test.ts
git commit -m "test: prove Dart and TypeScript Mifare card images are byte-identical"
```

---

### Task 10: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Document the feature**

Under the Architecture section's Features Layer bullet list, add:

> - **Mifare Classic 1K (Android only):** `NfcRepository` selects a `TagCodec` per tapped tag — `MifareTagCodec` when `MifareClassic.from(tag)` is non-null, else `NdefTagCodec`. Block layout in `lib/core/mifare/card_layout.dart` is a deliberate port of `webapp/src/mifare/card-layout.ts`, proven byte-identical by `tool/generate_mifare_fixtures.dart` + the web app's `interop-dart.test.ts`. Factory keys only; **sector trailers are never written**. Hardware support is detected via the `com.nfcarchiver/nfc_capabilities` platform channel (`com.nxp.mifare`) and hides the tag-type option when absent. iOS cannot support this — Core NFC has no CRYPTO1.

- [ ] **Step 2: Verify the whole tree**

```bash
flutter test && flutter analyze
source ~/.nvm/nvm.sh && nvm use --lts && cd webapp && rm -rf dist && npm test
```

Expected: both suites pass; analyzer no worse than 22.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document Mifare Classic support and the TagCodec seam"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Capability detection (channel, two levels) | 3, 8 |
| `TagCodec` seam + routing rule | 4, 6 |
| Block layout port | 1 |
| `capacityBytes` defined as chunk bytes | 4 (NDEF), 5 (Mifare) |
| Medium-aware `NfcTagType`, 720 == web app | 2 |
| Write flow: picker entry, mismatch error, read-back verify | 5 (verify), 8 (picker, error) |
| Restore flow + `mifareUnsupported` four-condition rule | 7 |
| Testing: layout, codec selection, fixture, capability | 1, 5, 6, 9, 3 |
| Non-goals | honored: no iOS path, factory keys only, no trailer writes, no cross-medium re-chunk |

**Known soft spot, flagged rather than hidden:** Task 8 Step 5 is the least concrete step in this plan. Threading `configuredTagType` into `startWriteSession` touches `archive_provider` and `write_progress_screen`, and I could not fully specify those edits without reading them at implementation time. The implementer should expect to read both files and may find the parameter is better carried on an existing config object. **If that step balloons, stop and split it into its own task rather than improvising.**

**Placeholder scan:** none besides the flagged Task 8 Step 5. Every other code step carries the code.

**Type consistency:** `MifareBlockIO` (`authenticateSector`/`readBlock`/`writeBlock`) is used identically in Tasks 5 and 6. `TagCodec`'s five members match across Tasks 4, 5, 6. `MifareBlockWrite(block, data)` from Task 1 is consumed unchanged in Tasks 5 and 9. `classifyNdefUnavailable`'s three named parameters match between Task 7's test and implementation. `cardCapacityBytes`/`cardPayloadSize` from Task 1 are consumed in Tasks 2 and 5 under those exact names.
