# Mifare Classic 4K Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read and write NFAR chunks on Mifare Classic 4K cards in the Flutter app and the web app, with 4K-sized writing hidden behind a developer switch until verified on real hardware.

**Architecture:** One ordered usable-block list per language whose first 47 entries are today's 1K list, so the 4K layout is a strict extension of 1K. A per-card size (1K / 4K) flows from SAK (Chameleon) or `MifareClassicAndroid.size` (phone radio); the *writable* capacity is gated by the developer switch, reading is not.

**Tech Stack:** Flutter/Dart (Riverpod, `nfc_manager` 4.2.1, `shared_preferences`), TypeScript web app (esbuild, `node --test`).

**Spec:** `docs/superpowers/specs/2026-11-11-mifare-classic-4k-design.md`

## Global Constraints

- **Nothing written to a 1K card changes**, byte for byte; the regenerated 1K fixture `webapp/test/fixtures/mifare-card.json` must be identical to the committed one.
- **Sector trailers are never written.** Factory key A (`FF FF FF FF FF FF`) only.
- Dart `lib/core/mifare/card_layout.dart` and TS `webapp/src/mifare/card-layout.ts` are mirror ports: same constants, same ordering. Change both or neither.
- 4K geometry: sectors 0–31 have 4 blocks (blocks 0–127), sectors 32–39 have 16 blocks (128–255); trailer = last block of each sector. Usable = all blocks except block 0 and trailers = **215 blocks = 3,440 B, payload 3,408 B**. 1K = 47 blocks = 752 B, payload 720 B.
- `sectorOf(block) = block < 128 ? block ~/ 4 : 32 + (block - 128) ~/ 16`.
- SAK classification: `0x08` → 1K; `0x18`, `0x38`, `0x98` → 4K; `0x00` → NTAG; anything else (incl. `0x19` 2K, `0x09` Mini) → unsupported.
- Switch off: a 4K card's writable capacity is 752 B (payload 720), 4K is not in any tag-type list. Reading and inspecting 4K are never gated.
- Chameleon writes of chunks > 752 B first do one factory-key read per touched sector; writes ≤ 752 B are unchanged (no extra round trips).
- Re-chunking stays first-card-only (existing behaviour).
- iOS phone radio and Web NFC: no Mifare, unchanged.
- Web dependency fence: `chameleon-ultra.js` only in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`; `webapp/src/` stays dependency-free.
- All new UI strings in all 7 locales: Flutter `lib/l10n/app_{en,ru,tr,uk,ka,pl,be}.arb` (+ `flutter gen-l10n`); web `webapp/app/i18n/*.ts` (`en.ts` is the schema).
- Log the SAK at info level on every Chameleon tap; never log card contents above debug.
- Web commands: `source ~/.nvm/nvm.sh && nvm use --lts`, then in `webapp/`: `rm -rf dist && npm test`.

## Review Focus

1. **Archive prepared at 3,408 B, then the switch is turned off (or a 4K card meets a 4K-sized chunk with the switch off)** → card is reported too small at 752 B (re-chunk offer if nothing written yet), never written. Test in Task 6 and Task 9.
2. **A 4K card holding a > 752 B chunk tapped with the switch off** → restores normally. Tests in Task 5, 6, 9.
3. **A 4K card whose sector 33 has a non-factory key, 4K-sized write** → fails before any block is written; card image unchanged. Tests in Task 5 (phone radio), 6 (Flutter Chameleon), 9 (web).
4. **Header declaring a length larger than the card** (> 752 on 1K, > 3,440 on 4K) → "not an NFAR card"/null, not a crash. Tests in Task 1 and 2.
5. **Emulated 4K (SAK `0x38`) goes through write+read; a 2K card (SAK `0x19`) is rejected as unsupported** for write, read and inspect. Tests in Task 6, 7, 9, 10.

---

### Task 1: Dart card layout for 1K and 4K

**Files:**
- Modify: `lib/core/mifare/card_layout.dart`
- Create: `lib/core/mifare/sak.dart`
- Test: `test/mifare_card_layout_test.dart`, create `test/mifare_sak_test.dart`

**Interfaces:**
- Produces:
  - `enum MifareCardSize { k1, k4 }` with `int get capacityBytes` (752 / 3440), `int get payloadSize` (capacity − `NfarHeaderSize.total`), `List<int> get usableBlocks`.
  - `final List<int> usableBlockIndexes4k` (215 entries); existing `usableBlockIndexes`, `cardCapacityBytes`, `cardPayloadSize` keep their 1K meaning (no call-site churn).
  - `int sectorOf(int block)`, `bool isSectorTrailer(int block)`, `int firstBlockOfSector(int sector)`.
  - `int writableCapacity(MifareCardSize size, {required bool allow4k})` → 3440 only for `k4 && allow4k`, else 752.
  - `List<MifareBlockWrite> chunkToBlocks(Uint8List chunkBytes, {MifareCardSize size = MifareCardSize.k1})`.
  - `int nfarTotalLength(Uint8List header, {MifareCardSize size = MifareCardSize.k1})`.
  - `sak.dart`: `enum TagKind { classic1k, classic4k, ntag, unsupported }`, `TagKind classifySak(int sak)`, `MifareCardSize? cardSizeFor(TagKind kind)`.

- [ ] **Step 1: Write failing tests** in `test/mifare_card_layout_test.dart`:
  - `usableBlockIndexes4k.length == 215`, `MifareCardSize.k4.capacityBytes == 3440`, `.payloadSize == 3408`; first 47 entries `== usableBlockIndexes`.
  - neither list contains block 0 or any of `[3, 7, …, 127, 143, 159, …, 255]`; 4K list contains 128 and 142, not 143.
  - `sectorOf(127) == 31`, `sectorOf(128) == 32`, `sectorOf(143) == 32`, `sectorOf(144) == 33`, `sectorOf(255) == 39`; `firstBlockOfSector(33) == 144`.
  - `chunkToBlocks(bytesOf(752 B))` (default) equals `chunkToBlocks(sameBytes, size: k4)`; a 3,000 B chunk with `size: k4` yields 188 writes, last block index `usableBlockIndexes4k[187]`; a 753 B chunk with default size throws `MifareCapacityException`; 3,441 B with `k4` throws.
  - `nfarTotalLength` on a header declaring payload 3,000: throws `FormatException` with default size, returns 3,032 with `k4`; payload 3,409 throws with `k4`. *(Review Focus 4)*
  - `writableCapacity(k4, allow4k: false) == 752`, `(k4, allow4k: true) == 3440`, `(k1, allow4k: true) == 752`.
- [ ] **Step 2: Write failing tests** in `test/mifare_sak_test.dart`: `classifySak(0x08) == classic1k`; `0x18`, `0x38`, `0x98` → `classic4k`; `0x00` → `ntag`; `0x19`, `0x09`, `0x28`, `0x20` → `unsupported`.
- [ ] **Step 3: Run** `flutter test test/mifare_card_layout_test.dart test/mifare_sak_test.dart` — expect compile failures / FAIL.
- [ ] **Step 4: Implement** in the two files. Build `usableBlockIndexes4k` by filtering `0..255` with `b != 0 && !isSectorTrailer(b)`; `isSectorTrailer(b) = b < 128 ? b % 4 == 3 : (b - 128) % 16 == 15`. Update the file header comment ("1K and 4K", strict-extension property).
- [ ] **Step 5: Run** the same command plus `flutter test test/mifare_tag_codec_test.dart test/chameleon_reader_test.dart` — expect PASS (defaults keep 1K behaviour).
- [ ] **Step 6: Commit** `feat(mifare): 4K card geometry and SAK classifier`.

### Task 2: TypeScript mirror and cross-language fixtures

**Files:**
- Modify: `webapp/src/mifare/card-layout.ts`, `tool/generate_mifare_fixtures.dart`, `webapp/test/interop-dart.test.ts`
- Create: `webapp/src/mifare/sak.ts`, fixture `webapp/test/fixtures/mifare-card-4k.json`
- Test: `webapp/test/card-layout.test.ts`, create `webapp/test/sak.test.ts`

**Interfaces:**
- Consumes: Task 1 semantics (mirror).
- Produces:
  - `export type CardSize = '1k' | '4k'`; `USABLE_BLOCK_INDEXES_4K`; `capacityBytes(size: CardSize): number`; `payloadSize(size: CardSize): number`; `usableBlocks(size: CardSize): readonly number[]`; `sectorOf(block: number): number`; `isSectorTrailer(block: number): boolean`; `firstBlockOfSector(sector: number): number`; `writableCapacity(size: CardSize, allow4k: boolean): number`.
  - `chunkToBlocks(chunkBytes: Uint8Array, size: CardSize = '1k')`, `nfarTotalLength(header: Uint8Array, size: CardSize = '1k')`.
  - `sak.ts`: `export type TagKind = 'classic1k' | 'classic4k' | 'ntag' | 'unsupported'`; `classifySak(sak: number): TagKind`; `cardSizeFor(kind: TagKind): CardSize | null`.
  - Existing exports (`USABLE_BLOCK_INDEXES`, `CARD_CAPACITY_BYTES`, `CARD_PAYLOAD_SIZE`) keep their 1K meaning.

- [ ] **Step 1: Write failing tests** — the same cases as Task 1 Steps 1–2, in `card-layout.test.ts` and `sak.test.ts`.
- [ ] **Step 2: Extend** `tool/generate_mifare_fixtures.dart` to also write `webapp/test/fixtures/mifare-card-4k.json` for a 3,000 B payload chunk (same archive-id/fill pattern style as the 1K one) laid out with `size: MifareCardSize.k4`; add a test in `interop-dart.test.ts` asserting `chunkToBlocks(chunk, '4k')` equals the fixture block-for-block, including at least one block ≥ 144.
- [ ] **Step 3: Run** `dart run tool/generate_mifare_fixtures.dart`, then `git diff --exit-code webapp/test/fixtures/mifare-card.json` — expect no diff (1K unchanged).
- [ ] **Step 4: Run** web tests — expect FAIL on the new tests.
- [ ] **Step 5: Implement** the TS mirror.
- [ ] **Step 6: Run** `rm -rf dist && npm test` — expect PASS.
- [ ] **Step 7: Commit** `feat(webapp): 4K card layout mirror with Dart interop fixture`.

### Task 3: Flutter developer switch

**Files:**
- Create: `lib/core/providers/dev_options_provider.dart`, `lib/features/dev_options/presentation/dev_options_screen.dart`
- Modify: `lib/shared/widgets/home_screen.dart` (footer tap counter; About dialog entry), `lib/app.dart` (route), `lib/main.dart` (if prefs are preloaded there, follow `locale_provider.dart`'s pattern), 7 ARB files
- Test: create `test/dev_options_test.dart`

**Interfaces:**
- Produces:
  - `class DevOptions { final bool unlocked; final bool mifare4k; }`
  - `final devOptionsProvider = StateNotifierProvider<DevOptionsNotifier, DevOptions>` with `Future<void> unlock()`, `Future<void> setMifare4k(bool on)`; prefs keys `dev.unlocked`, `dev.mifare4k`; both default false.
  - `final mifare4kEnabledProvider = Provider<bool>((ref) => ref.watch(devOptionsProvider).mifare4k)`.
  - `const devOptionsRoute = '/developer-options'`.
  - ARB keys: `developerOptions` ("Developer options"), `developerOptionsUnlocked` ("Developer options enabled"), `mifare4kToggle` ("Mifare Classic 4K"), `mifare4kToggleSubtitle` ("Experimental — not yet verified on a real card").

- [ ] **Step 1: Write failing tests** in `test/dev_options_test.dart` (use `SharedPreferences.setMockInitialValues`):
  - fresh prefs → `unlocked == false`, `mifare4k == false`, `mifare4kEnabledProvider` false.
  - `setMifare4k(true)` persists: a new `ProviderContainer` reading the same mock prefs sees `mifare4k == true`.
  - widget test: pump home screen, tap the version footer 6 times → no "Developer options" in the About dialog; 7th tap → snackbar `developerOptionsUnlocked`, and the About dialog shows a `developerOptions` button that navigates to `DevOptionsScreen`.
  - widget test: `DevOptionsScreen` switch toggles `mifare4kEnabledProvider`.
- [ ] **Step 2: Run** `flutter test test/dev_options_test.dart` — expect FAIL.
- [ ] **Step 3: Implement.** Footer: wrap the version `Text` in a `GestureDetector`; counter resets after 2 s idle; once unlocked further taps do nothing. Screen: a `SwitchListTile` with the two strings. Add the four ARB keys to all 7 files, run `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter test test/dev_options_test.dart` and the l10n tests — expect PASS.
- [ ] **Step 5: Commit** `feat: hidden developer options with a Mifare Classic 4K switch`.

### Task 4: Flutter tag type, picker gating and medium-aware re-chunk

**Files:**
- Modify: `lib/core/constants/nfar_format.dart`, `lib/features/nfc/domain/tag_type_availability.dart`, `lib/features/archive/presentation/screens/archive_settings_screen.dart`, `lib/features/archive/presentation/screens/write_progress_screen.dart:113-135`, `lib/features/archive/presentation/providers/archive_provider.dart:416`
- Test: `test/mifare_availability_test.dart`, `test/archive_settings_tag_types_test.dart`, create `test/rechunk_payload_test.dart`

**Interfaces:**
- Consumes: `mifare4kEnabledProvider` (Task 3).
- Produces:
  - `NfcTagType.mifareClassic4k(name: 'Mifare Classic 4K', capacity: 3440, medium: TagMedium.mifareClassic)`, placed right after `mifareClassic1k`.
  - `List<NfcTagType> selectableTagTypes({required bool mifareAvailable, required bool mifare4kEnabled})`.
  - `static int NfcTagType.payloadForCapacity(int capacity, TagMedium medium)` — Mifare: `capacity - NfarHeaderSize.total`; NDEF: delegates to `maxPayloadForCapacity`.
  - `int? rechunkForDetectedCapacity(int detectedCapacity, {TagMedium medium = TagMedium.ndef})`.

- [ ] **Step 1: Write failing tests:**
  - `selectableTagTypes(mifareAvailable: true, mifare4kEnabled: false)` excludes `mifareClassic4k`, includes `mifareClassic1k`; `(true, true)` includes both; `(false, true)` includes neither. Update existing calls in the test file for the new required parameter.
  - `NfcTagType.mifareClassic4k.maxPayloadSize == 3408`.
  - `payloadForCapacity(752, TagMedium.mifareClassic) == 720`; `payloadForCapacity(3440, TagMedium.mifareClassic) == 3408`; `payloadForCapacity(504, TagMedium.ndef) == NfcTagType.maxPayloadForCapacity(504)`.
  - `rechunkForDetectedCapacity(752, medium: TagMedium.mifareClassic)` on an `ArchiveReady` with no written chunks re-chunks to payload 720 (assert resulting chunk payload sizes ≤ 720 and at least one == 720).
  - widget test (`archive_settings_tag_types_test.dart`): with Mifare reader and switch on, select 4K, turn switch off → selection resets to `mifareClassic1k`; with a non-Mifare reader → `ntag216` (existing rule).
- [ ] **Step 2: Run** those tests — expect FAIL.
- [ ] **Step 3: Implement.** In the settings screen, extend the existing post-frame reset: if `tagType == mifareClassic4k && !mifare4kEnabled` → `mifareAvailable ? mifareClassic1k : _fallbackTagType`. In `_showRechunkDialog` use `next.tagInfo?.effectiveTagType.medium ?? TagMedium.ndef` (from `NfcSessionTagTooSmall.tagInfo`) with `payloadForCapacity`, and pass the same medium to `rechunkForDetectedCapacity`. Remove the "currently unreachable" paragraph in `nfc_repository.dart` around line 459 (it is now reachable and fixed).
- [ ] **Step 4: Run** `flutter test` — expect PASS.
- [ ] **Step 5: Commit** `feat: Mifare Classic 4K tag type behind the switch; medium-aware re-chunk`.

### Task 5: Android phone-radio codec for 4K

**Files:**
- Modify: `lib/features/nfc/domain/mifare_block_io.dart`, `lib/features/nfc/domain/mifare_tag_codec.dart`, `lib/features/nfc/data/nfc_repository.dart` (codec construction; tag-type detection for Mifare)
- Test: `test/mifare_tag_codec_test.dart`

**Interfaces:**
- Consumes: Task 1 layout; `mifare4kEnabledProvider` value passed in as a callback.
- Produces:
  - `MifareBlockIO` gains `MifareCardSize? get cardSize` — `NfcManagerMifareBlockIO` returns `k1` for `size == 1024`, `k4` for `size == 4096`, null otherwise.
  - `mifareIoFor(tag)` returns null when `cardSize` is null (2K/Mini/Plus-SL: not offered, consistent with spec; the tag then falls through to the NDEF codec as today's non-Mifare tags do).
  - `MifareTagCodec(MifareBlockIO? Function(NfcTag) ioFor, {bool Function() allow4k = _never})`.
  - `capacityBytes(tag)` returns `writableCapacity(io.cardSize, allow4k: allow4k())`.
  - Tag info for a 4K card on Android: `tagType = mifareClassic4k`, `capacity` = writable capacity.

- [ ] **Step 1: Write failing tests** with the existing fake `MifareBlockIO` extended with a `cardSize` and per-sector keys:
  - 4K fake, `allow4k: () => true`: write a 3,000 B chunk, read it back equal; authenticated sectors include 32 and 33; no write ever targets a trailer (143, 159, …).
  - 4K fake, `allow4k: () => false`: `capacityBytes == 752`; a fake holding a 3,000 B chunk written beforehand still reads back. *(Review Focus 2)*
  - 4K fake with sector 33 keyed non-factory: 3,000 B write throws `MifareAuthException(33)` and no block was written. *(Review Focus 3)*
  - 4K fake: a 700 B chunk produces exactly the same `(block, data)` writes as the 1K fake.
  - `_sectorOf` regression: writing to block 144 authenticates sector 33, not 36.
- [ ] **Step 2: Run** `flutter test test/mifare_tag_codec_test.dart` — expect FAIL.
- [ ] **Step 3: Implement.** Replace `block ~/ 4` with `sectorOf`; iterate `io.cardSize!.usableBlocks`; pass `size` to `chunkToBlocks`/`nfarTotalLength`. In `NfcRepository`, construct the codec with `allow4k` reading the switch (inject a `bool Function()` from the provider layer; follow how other settings reach the repository).
- [ ] **Step 4: Run** `flutter test` — expect PASS.
- [ ] **Step 5: Commit** `feat(nfc): Mifare Classic 4K on the Android phone radio`.

### Task 6: Flutter Chameleon reader for 4K

**Files:**
- Modify: `lib/features/nfc/data/chameleon_reader.dart` (write path ~184, `_readChunkBytes` ~341, `_readClassic`, `_writeClassic` ~445, `_tagInfo` ~496), `lib/core/chameleon/chameleon_device.dart` (doc comment), `test/support/fake_chameleon_device.dart`
- Test: `test/chameleon_reader_test.dart`, `test/fake_chameleon_device_test.dart`

**Interfaces:**
- Consumes: Task 1 (`classifySak`, `cardSizeFor`, layout), `mifare4kEnabledProvider`.
- Produces:
  - `ChameleonReader(..., {bool Function() allow4k = _never})` — wired from the reader provider.
  - `FakeChameleonDevice.classic4k({Map<int, Uint8List>? sectorKeys, int seed = 0, int sak = 0x18})` — 256 blocks; per-sector keys use real 4K sector numbering.

- [ ] **Step 1: Write failing tests:**
  - fake: `classic4k()` rejects a read of block 144 when sector 33 has a custom key, accepts block 143 reads (trailer readable, as on 1K).
  - allow4k on: 3,000 B chunk writes and reads back on `classic4k()`; also on `classic4k(sak: 0x38)`. *(Review Focus 5)*
  - allow4k off: 3,000 B write → `onTagTooSmall(3032, 752, info)`, no block written; a card pre-filled (via a write with allow4k on, then a reader with it off) still reads. *(Review Focus 1, 2)*
  - pre-check: sector 33 custom key, 3,000 B write → error reported, fake records zero block writes. *(Review Focus 3)*
  - ≤ 752 B write on `classic4k()` and on `classic1k()`: same block writes; the reader issued no pre-check reads (assert read count == write count, i.e. only verify reads).
  - SAK `0x19` card → unsupported-tag failure on read and on write. *(Review Focus 5)*
  - `_tagInfo` for a 4K card: `tagType == mifareClassic4k`, `capacity == 3440` with allow4k on, `752` off.
  - log: an info entry with the SAK on each tap.
- [ ] **Step 2: Run** `flutter test test/chameleon_reader_test.dart test/fake_chameleon_device_test.dart` — expect FAIL.
- [ ] **Step 3: Implement.** Route on `classifySak`; read with `cardSizeFor(kind)!.usableBlocks` and `nfarTotalLength(…, size:)`; write capacity check uses `writableCapacity(size, allow4k: allow4k())`; for chunks > 752 B, before the first write call `_device.readBlock(sector == 0 ? 1 : firstBlockOfSector(sector), factoryKeyA)` for each touched sector and fail on error.
- [ ] **Step 4: Run** `flutter test` — expect PASS.
- [ ] **Step 5: Commit** `feat(chameleon): Mifare Classic 4K through the Chameleon in the Flutter app`.

### Task 7: Flutter card inspector for 4K

**Files:**
- Modify: `lib/core/inspect/card_dump.dart` (`_classicBlocks`, `block ~/ 4` at ~171, SAK routing ~145), `lib/features/inspect/domain/run_inspection.dart:65`
- Test: `test/inspect_card_dump_test.dart`, `test/run_inspection_test.dart`

**Interfaces:**
- Consumes: Task 1, Task 6 fake.
- Produces: `dumpCard` handles 4K (256 units, `sector = sectorOf(block)`, trailer kind via `isSectorTrailer`); `run_inspection` uses the dumped card's capacity (`MifareCardSize.capacityBytes`, ungated).

- [ ] **Step 1: Write failing tests:** dump of `classic4k()` has 256 units, unit 143 and 255 are trailers, unit 144 has `sector == 33`; a 3,000 B NFAR chunk on a 4K card is described as a valid chunk (CRC ok) by `run_inspection`; SAK `0x19` → unsupported message. *(Review Focus 5)*
- [ ] **Step 2: Run** those tests — expect FAIL.
- [ ] **Step 3: Implement.** Update the "1K" wording in user-visible inspector strings only if they name the size (keep the inspection report English, per repo rule).
- [ ] **Step 4: Run** `flutter test` — expect PASS.
- [ ] **Step 5: Commit** `feat(inspect): dump Mifare Classic 4K cards`.

### Task 8: Web developer switch and target-tag option

**Files:**
- Create: `webapp/app/dev-flags.ts`
- Modify: `webapp/app/ui/about-panel.ts`, `webapp/app/index.html` (`#target-tag`), `webapp/app/ui/archive-panel.ts` (`selectedPayloadSize`, `syncTargetTagForReader`), `webapp/app/i18n/*.ts`
- Test: create `webapp/test/dev-flags.test.ts`; extend `webapp/test/i18n.test.ts` / `markup-ids.test.ts` only if they enumerate options

**Interfaces:**
- Produces:
  - `dev-flags.ts`: `isDevUnlocked(): boolean`, `unlockDev(): void`, `isMifare4kEnabled(): boolean`, `setMifare4kEnabled(on: boolean): void`, `onMifare4kChange(cb: (on: boolean) => void): () => void`. Keys `nfar-dev-unlocked`, `nfar-dev-mifare4k`; every storage access in try/catch, defaulting to false.
  - `<option value="3408" hidden>Mifare Classic 4K — 3440 B</option>` after the 1K option.
  - i18n keys: `devOptions`, `devUnlocked`, `mifare4kToggle`, `mifare4kHint` (same English copy as Task 3).

- [ ] **Step 1: Write failing tests** in `dev-flags.test.ts` (stub `globalThis.localStorage` with a Map-backed object, and one that throws): defaults false; set/get round-trip; throwing storage → false, no exception; `onMifare4kChange` fires on set.
- [ ] **Step 2: Run** web tests — expect FAIL.
- [ ] **Step 3: Implement.** About panel: 7 clicks on the version line (2 s idle reset) → `unlockDev()`, show `devUnlocked`, render a checkbox `mifare4kToggle` with hint. Archive panel: the 4K option is `hidden = !isMifare4kEnabled()` and disabled under Web NFC exactly like `value="720"`; if it is selected when the switch turns off or Web NFC becomes active, move selection to `"720"` (Chameleon) or `"NTAG215"` (Web NFC). `selectedPayloadSize()` already returns `Number(v)` for numeric values.
- [ ] **Step 4: Run** `rm -rf dist && npm test` — expect PASS (i18n completeness included).
- [ ] **Step 5: Commit** `feat(webapp): hidden developer switch for Mifare Classic 4K`.

### Task 9: Web transports for 4K

**Files:**
- Modify: `webapp/src/transport/chameleon-ble.ts`, `webapp/src/transport/auto-transport.ts`, `webapp/src/transport/chameleon-device.ts` (doc comment), `webapp/app/ui/device.ts` (pass the flag), `webapp/test/fake-chameleon.ts`
- Test: `webapp/test/chameleon-ble.test.ts`, `webapp/test/auto-transport.test.ts`, `webapp/test/e2e-mifare.test.ts`, `webapp/test/controller.test.ts`

**Interfaces:**
- Consumes: Task 2 (`classifySak`, `cardSizeFor`, layout), Task 8 (`isMifare4kEnabled`).
- Produces:
  - `ChameleonBleTransport` / `AutoTransport` opts gain `allow4k?: () => boolean` (default `() => false`). `webapp/src` must not import `app/` — `device.ts` passes `isMifare4kEnabled`.
  - `awaitTag` on a Classic card returns `capacityBytes = capacityBytes(size)` and `maxChunkPayload = writableCapacity(size, allow4k()) - TOTAL_OVERHEAD`.
  - `FakeChameleon.defineCard(uid, opts?: { keyA?; sak?; size?: CardSize; sectorKeys?: Map<number, Uint8Array> })` — image is 256×16 for `'4k'` (default size from SAK via `cardSizeFor(classifySak(sak))`, else `'1k'`).

- [ ] **Step 1: Write failing tests:**
  - `AutoTransport` routes SAK `0x18`/`0x38`/`0x98` to Classic, `0x19` → `UnsupportedTagError`. *(Review Focus 5)*
  - allow4k on: `maxChunkPayload == 3408` for a 4K card; 3,000 B write + read round trip; off: `maxChunkPayload == 720`, and a 4K card pre-written with a 3,000 B chunk still reads. *(Review Focus 2)*
  - `controller.test.ts`: target "auto", switch off, first card 4K → archive re-sized to payload 720, not 3,408 (anti-goal); switch on → 3,408. With `"3408"` selected, archive prepared, switch then turned off, first card a 4K → archive re-sized to 720 (existing first-card rule); same after one card is written → `CardCapacityError`. Never a 4K-sized write. *(Review Focus 1)*
  - sector 33 custom key, 3,000 B write → `CardAuthError`, fake records zero writes. *(Review Focus 3)*
  - ≤ 752 B write on a 4K card: block writes identical to 1K, no pre-check reads.
- [ ] **Step 2: Run** web tests — expect FAIL.
- [ ] **Step 3: Implement.** `ChameleonBleTransport` remembers the size of the tag from `awaitTag` (via `scanTag().sak`) and uses `usableBlocks(size)` / `nfarTotalLength(header, size)` / `chunkToBlocks(bytes, size)`; pre-check for > 752 B mirrors Task 6. Replace the SAK branch in `AutoTransport` with `classifySak`, and log the SAK at info level on each tap through the existing `webapp/src/log` logger.
- [ ] **Step 4: Run** `rm -rf dist && npm test` — expect PASS.
- [ ] **Step 5: Commit** `feat(webapp): Mifare Classic 4K through the Chameleon`.

### Task 10: Web card inspector for 4K

**Files:**
- Modify: `webapp/src/inspect/card-dump.ts` (`CLASSIC_BLOCKS`, SAK routing ~67, medium type), `webapp/src/inspect/hex-view.ts` (~62, ~85), `webapp/src/inspect/nfar-describe.ts` if it caps at 752
- Test: `webapp/test/card-dump.test.ts`, `webapp/test/hex-view.test.ts`, `webapp/test/nfar-describe.test.ts`

**Interfaces:**
- Consumes: Task 2, Task 9 fake.
- Produces: `DumpMeta.medium: 'mifare-classic-1k' | 'mifare-classic-4k' | NtagType`; 4K dump has 256 units with trailers at `isSectorTrailer`; hex view labels "Mifare Classic 4K" and groups by real sector; `describeNfar` caps by the dumped card's capacity (ungated).

- [ ] **Step 1: Write failing tests:** 4K dump → 256 units, trailers 143/255, sector of 144 is 33; 3,000 B chunk described as valid; SAK `0x19` → unsupported message naming 1K, 4K and NTAG. *(Review Focus 5)*
- [ ] **Step 2: Run** web tests — expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `rm -rf dist && npm test` — expect PASS.
- [ ] **Step 5: Commit** `feat(webapp): inspect Mifare Classic 4K cards`.

### Task 11: Documentation and full verification

**Files:**
- Modify: `CLAUDE.md` (Mifare bullets in Architecture; web app "Media" bullet), `webapp/README.md` (media list, developer switch, unverified status)

- [ ] **Step 1: Update docs:** 4K = strict extension of the 1K layout; SAK set; switch location in both apps (7 taps on version → Developer options); reading/inspecting ungated; **unverified on real hardware** with a pointer to the spec's checklist; Chameleon pre-check applies to > 752 B writes only. `aboutSupportedTags` is **not** changed (4K is hidden).
- [ ] **Step 2: Run** `flutter analyze` — expect "No issues found!".
- [ ] **Step 3: Run** `flutter test` — expect all pass.
- [ ] **Step 4: Run** in `webapp/`: `rm -rf dist && npm test` and `npm run build:site` — expect pass.
- [ ] **Step 5: Run** `dart run tool/generate_mifare_fixtures.dart && git diff --exit-code webapp/test/fixtures/mifare-card.json` — expect no diff.
- [ ] **Step 6: Commit** `docs: Mifare Classic 4K (hidden, unverified)`.
