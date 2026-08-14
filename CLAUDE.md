# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
flutter pub get

# Generate localization files (required before build/run)
flutter gen-l10n

# Run on connected device
flutter run

# Analyze code for errors
flutter analyze

# Run all tests
flutter test

# Run single test file
flutter test test/encryption_test.dart

# Run tests with coverage
flutter test --coverage

# Build APK (Android)
flutter build apk

# Build iOS (requires macOS + Xcode)
flutter build ios
```

## Architecture

Flutter app for distributed file storage across NFC tags using the NFAR (NFC Archive) binary format.

### Data Flow

**Archive:** File → (compress) → (encrypt) → chunk into NFAR packets → write to NFC tags

**Restore:** Scan NFC tags in any order → collect chunks by Archive ID (UUID) → assemble → (decrypt) → (decompress) → File

### Core Layer (`lib/core/`)

- **`constants/nfar_format.dart`** — NFAR v1 binary format (28-byte header + payload + CRC32). All multi-byte values big-endian. `NfarFlags` for compression/encryption bits, `NfcTagType` enum for tag capacity calculations.
- **`models/chunk.dart`** — `Chunk` class with `toBytes()`/`fromBytes()` serialization
- **`services/chunker_service.dart`** — Splits data into chunks via `createChunks()` or `createChunksWithSize()`, reassembles with `assembleChunks()` including CRC32 validation
- **`services/encryption_service.dart`** — AES-256-GCM encryption with PBKDF2 (100k iterations). Format: salt(16) + IV(12) + ciphertext + tag(16). Use `encryptionOverhead` constant when calculating sizes.
- **`services/compression_service.dart`** — GZIP compression wrapper

### Features Layer (`lib/features/`)

Each feature follows: `data/` (repository) → `presentation/providers/` (Riverpod StateNotifier) → `presentation/screens/`

- **`nfc/`** — NFC abstraction over `nfc_manager`. `NfcRepository` manages sessions with write cooldown to prevent re-read. `NdefFormatter` converts Chunk↔NDEF with MIME type `application/vnd.nfcarchiver.chunk`.
- **Mifare Classic 1K (built-in radio: Android only):** `NfcRepository` selects a `TagCodec` per tapped tag — `MifareTagCodec` when `MifareClassic.from(tag)` is non-null, else `NdefTagCodec`. Block layout in `lib/core/mifare/card_layout.dart` is a deliberate port of `webapp/src/mifare/card-layout.ts`, proven byte-identical by `tool/generate_mifare_fixtures.dart` + the web app's `interop-dart.test.ts`. Factory keys only; **sector trailers are never written**.
- **Who may offer Mifare Classic is a property of the READER, not the phone.** CRYPTO1 lives in the reader chip, so the question is asked through `CardReader.supportsMifareClassic()`: `PhoneNfcReader` answers from the `com.nfcarchiver/nfc_capabilities` platform channel (`com.nxp.mifare`, absent on iOS ⇒ false), `ChameleonReader` answers `true` unconditionally. The archive settings screen filters the tag-type list on `mifareClassicAvailableProvider`, which is derived from the **active** reader, so connecting a Chameleon adds the medium and dropping one takes it away — and resets a now-unwritable Mifare selection to NTAG216. Gating on the phone alone hid the app's primary medium on every iPhone even with a reader attached; don't reintroduce a phone-wide check.
- **`archive/`** — `ArchiveNotifier` uses sealed class states (`ArchiveInitial` → `ArchiveFileSelected` → `ArchiveConfiguring` → `ArchivePreparing` → `ArchiveReady` → `ArchiveWriting` → `ArchiveComplete`). Supports `rechunkForDetectedCapacity()` when tag is smaller than expected.
- **`restore/`** — `RestoreNotifier` with states for scanning, collecting chunks into `RestoreSession` by UUID, handling CRC errors with rescan capability.

### State Management

Riverpod with `StateNotifier` pattern using sealed classes for type-safe state transitions:
- `archiveProvider` — Archive creation workflow
- `restoreProvider` — Restore/scanning workflow

### NFAR Format

28-byte header. Flags byte: bit 0 = GZIP, bit 1 = AES-256-GCM. Archive ID is UUID v4 (16 bytes) for grouping chunks. Max 65535 chunks per archive. Chunks validated with CRC32 and can be scanned in any order.

### File Sharing (`share_plus`)

All `Share.shareXFiles` calls include explicit MIME types resolved via the `mime` package (`lookupMimeType()`) from file extensions. This is required for Telegram and other strict Android apps that validate content before enabling the send button. Without MIME types, Android's `ContentResolver` reports `application/octet-stream` and the receiving app may refuse to send.

`AndroidManifest.xml` declares `SEND` and `SEND_MULTIPLE` intent queries for proper share target resolution on Android 11+ (API 30+ package visibility).

### Version Display

Version and build number are read at runtime via `PackageInfo.fromPlatform()` (`package_info_plus` package) — **never hardcoded**. `pubspec.yaml` `version:` field is the single source of truth. The version propagates to:
- **Home screen footer**: `"NFC Archiver v1.0.10 (Build 10) © 2026"` via parameterized `versionFooter` l10n key
- **About dialog**: `applicationVersion` parameter in `showAboutDialog()`
- **Android APK**: `build.gradle` reads `flutter.versionName`/`flutter.versionCode` from pubspec

To release a new version: bump `version: X.Y.Z+N` in `pubspec.yaml` (increment both version name and build number). Nothing else needs updating.

### Localization

Uses Flutter's `gen-l10n` with ARB files in `lib/l10n/`. Supported: English (`app_en.arb`), Russian (`app_ru.arb`), Turkish (`app_tr.arb`), Ukrainian (`app_uk.arb`), Georgian (`app_ka.arb`), Polish (`app_pl.arb`), Belarusian (`app_be.arb`). Run `flutter gen-l10n` after modifying ARB files. All new UI strings must be added to `app_en.arb` (template) and all 6 translation files.

### Fastlane Metadata

Fastlane metadata lives in `fastlane/metadata/android/<locale>/`. Each locale directory must contain `title.txt`, `short_description.txt`, `full_description.txt`, and a `changelogs/` directory. Changelogs use the naming convention `<versionCode>.txt` (matching the build number from `pubspec.yaml`).

**When releasing a new version:** add a changelog file `<versionCode>.txt` to **all 7 locale directories** (`en-US`, `ru-RU`, `tr-TR`, `uk`, `ka-GE`, `pl-PL`, `be-BY`). Without translated changelogs, Google Play and F-Droid fall back to English for non-English users.

## Web App (`webapp/`)

A browser port that reads/writes NFAR archives on physical cards, either via a Chameleon Ultra over Web Bluetooth or, on Chrome for Android, the phone's own Web NFC radio — see [`webapp/README.md`](webapp/README.md) for the full picture. Key facts for working in it:

- **TypeScript + esbuild, no UI framework.** The core (`webapp/src/`) is dependency-free and uses only web-platform globals (`crypto.subtle`, `CompressionStream`, `DataView`), so it runs both in the browser and under `node --test`.
- **On-tag bytes are byte-compatible with the Flutter app** — same NFAR chunk format, same filename wrapper (`_prependFilenameMetadata`), and for NTAG the same NDEF MIME record (`application/vnd.nfcarchiver.chunk`). Cross-language interop is proven by `tool/generate_web_fixtures.dart` / `tool/verify_web_fixtures.dart`, which use the app's production `lib/core` services.
- **Media:** Mifare Classic 1K (`card-layout.ts`, 47 usable blocks = 752 B) and NTAG213/215/216 (`nfc/ndef.ts` + `nfc/type2.ts`). `AutoTransport` routes each tapped tag by SAK. `FakeChameleon` simulates both media so all transports are tested without hardware.
- **Card inspector:** the device-bar "Inspect card" button dumps the presented card into a modal — identity, decoded NFAR header with CRC verification, and raw hex/ASCII per block/page. Logic is in `src/inspect/` (dependency-free: `card-dump.ts`, `nfar-describe.ts`, `hex-view.ts`) plus `app/ui/inspect-orchestrator.ts` behind an `InspectIO` seam, so it is tested without a DOM stub. `describeNfar` is deliberately tolerant where `decodeChunk` throws — in an inspector the failure is the information. Read-only; `Transport` is untouched because a raw dump is not a chunk operation.
- **Readers:** two transports behind the same `Transport` seam. `AutoTransport` over a Chameleon (Mifare Classic + NTAG, full raw access), and `WebNfcTransport` over the phone's own radio (`app/ui/browser-ndef-io.ts` is the only file touching `NDEFReader`). Web NFC is Chrome-on-Android only, NDEF-only — no Mifare, no card inspector — and exposes no capability container, so chunk size comes from the explicitly selected tag type via `webNfcChunkPayload()` (factory CC: 144/496/872), never the raw-memory estimate. Unverified on real Chrome — see `webapp/README.md`.
- **Localization:** seven locales (en, ru, tr, uk, ka, pl, be) in `app/i18n/`, bundled as typed modules. `en.ts` is the schema — every other catalogue is `: Messages`, so `tsc` fails until a new key is translated everywhere. Static markup is annotated with `data-i18n` and validated by `test/i18n.test.ts`. Log entries and the card-inspection report deliberately stay English.
- **Dependency fence:** the only runtime dep, `chameleon-ultra.js`, may be imported ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`. The core stays dependency-free.
- **Commands (Node ≥ 22 required):** `source ~/.nvm/nvm.sh && nvm use --lts` first (the shell default is Node 14). `rm -rf dist && npm test` (the `tsc && node --test` chain doesn't clean stale compiled tests). `npm run app` serves it on `localhost:8000`. Web Bluetooth is Chromium-only; inside WSL the browser must run on the Windows host.
- **Deploy:** manual only, from `master` — `gh workflow run deploy-webapp.yml --ref master` (add `-f dry_run=true` to print the sync plan without uploading). `npm run build:site` produces the deployable `site/` tree and stamps an esbuild banner `/* nfar-build:<sha> */` into the bundle; the post-deploy healthcheck requires the live bundle to carry that marker, and rolls back if it doesn't. Match on the **marker, never the bare SHA** — the bundle contains hex constants like `"C82000000000"`, so a 7-hex-char needle can match by coincidence and pass a stale deploy. Credentials come from GitHub OIDC; there are no stored AWS keys. Every S3 and CloudFront operation is confined to the `app/` prefix because the `nfcarchiver.com` bucket hosts other applications. See `webapp/README.md` for the configuration table and why the non-credentials are variables rather than secrets.
- **Status:** working prototype, validated on real hardware. Deferred: an IndexedDB file manager (Files tab is a placeholder).

## Apple App Store Publishing

**Goal:** Publish NFC Archiver to the Apple App Store.

### Steps to Resolve

1. **Apple Developer Account** — Enroll in the Apple Developer Program ($99/year) if not already enrolled
2. **App Store Connect setup** — Create the app record in App Store Connect with bundle ID, app name, and category
3. **App icons & screenshots** — Prepare required app icon sizes (1024x1024 for store) and screenshots for all required device sizes (6.7", 6.5", 5.5" iPhones; iPad Pro)
4. **App Store metadata** — Write app description, keywords, subtitle, promotional text, and select appropriate categories
5. **Privacy policy URL** — Host `PRIVACY_POLICY.md` at a public URL (required by Apple for apps accessing NFC/files); reference it in App Store Connect
6. **Age rating questionnaire** — Complete the age rating questionnaire in App Store Connect
7. **Review NFC entitlements** — Ensure `ios/Runner/Runner.entitlements` has the correct NFC tag reading capability; already added in commit `25ee496`
8. **Signing & provisioning** — Configure distribution certificate and App Store provisioning profile in Xcode
9. **Build & upload** — Build release IPA via `flutter build ipa` and upload via Xcode or `xcrun altool`
10. **TestFlight** — Distribute a build via TestFlight for pre-release testing before submitting for review
11. **App Review submission** — Submit for Apple review; address any rejection feedback

## iOS Development (Mac)

### The two radios have very different gates

|  | Core NFC | Core Bluetooth (Chameleon) |
|---|---|---|
| Entitlement | `com.apple.developer.nfc.readersession.formats` — **paid programme only** | none |
| Free Personal Team | session fails with a *sandbox restriction* | works |
| Mifare Classic | **impossible** — Core NFC has no CRYPTO1 | works, via the reader |
| Info.plist | `NFCReaderUsageDescription` | `NSBluetoothAlwaysUsageDescription` |

**A missing `NSBluetoothAlwaysUsageDescription` does not degrade — iOS terminates the app** on the first Core Bluetooth call.

The consequence is counter-intuitive and worth stating plainly: **the Chameleon route makes iOS *more* capable than the phone's own radio.** Native iOS NFC can never touch Mifare Classic, the app's primary medium; routed through the reader it can, because CRYPTO1 runs on the Chameleon. So a free Apple account plus a Chameleon is a working iOS setup, while a free account with no reader is not.

`ChameleonReader.isAvailable()` and `ChameleonReader.supportsMifareClassic()` both return `true` unconditionally, and the class imports nothing from `nfc_manager`, so the reader path is independent of Core NFC by construction — keep it that way. The UI must never fall back to a phone-wide capability check for either: doing so is what once hid Mifare Classic on iOS with a Chameleon connected.

### What the Chameleon path does NOT verify

It bypasses `nfc_manager` entirely (it uses `lib/core/chameleon/`), so it exercises **none** of `IosNdefIO`, `NdefStatusIos`, or the `defaultTargetPlatform` guards in `ndefIoFor`/`mifareIoFor`. Verifying those needs Core NFC, hence the paid programme. Don't let a green Chameleon run on iOS be mistaken for iOS coverage of the `nfc_manager` layer.

### Toolchain

- **Xcode 26 is the last version supporting Intel Macs**; macOS Tahoe 26 is the last macOS for Intel. Xcode 27 is Apple Silicon only. An Intel Mac works for now — don't plan around it long-term.
- **Xcode is not installable from the App Store on Sequoia.** The App Store only ever offers the newest Xcode, and 26.4+ requires macOS Tahoe 26.2. On macOS 15.x get the `.xip` for **Xcode 26.3** from <https://developer.apple.com/download/all/?q=xcode> — a free Apple ID is enough, no paid membership.
- Free Personal Team builds **expire after 7 days** and must be re-deployed from Xcode; 3 apps max; no TestFlight.
- `IPHONEOS_DEPLOYMENT_TARGET` is `13.0`, matching the Flutter 3.44 template. It was `12.0`, which no longer builds: `pod install` fails against the Flutter podspec. If a Flutter upgrade raises the template's target again, this must follow.
- Pin Flutter to the CI version by tag (see the version in `.github/workflows/ci.yml`), then `flutter pub get`. **Do not run `pod install` first** — `ios/Podfile` is generated, not tracked, and only `flutter build ios` / `flutter run` creates it. `flutter pub get` alone does not.
- Enable Developer Mode on the iPhone (Settings → Privacy & Security) before the first `flutter run`.

### Signing on a free Apple ID

`Runner.entitlements` requests `com.apple.developer.nfc.readersession.formats`, and **a Personal Team cannot sign it** — Xcode refuses to create the provisioning profile, so a device build dies at signing before the app launches. Simulator builds are unaffected (they are not signed at all).

`CODE_SIGN_ENTITLEMENTS` is therefore indirected through `$(NFAR_CODE_SIGN_ENTITLEMENTS)`, defaulted in `ios/Flutter/Debug.xcconfig` and `Release.xcconfig`. To build on a free account, create the gitignored `ios/Flutter/LocalOverrides.xcconfig` containing `NFAR_CODE_SIGN_ENTITLEMENTS =` (empty). You lose Core NFC and keep the Chameleon — which, per the table above, is the only path to Mifare Classic anyway.

**Only `Debug.xcconfig` includes that override.** `Release.xcconfig` (shared with Profile) hardcodes the entitlements path, so the workaround cannot leak into a shipped IPA. Keep it that way — an IPA that silently lost the entitlement ships an app whose NFC is dead, and nobody finds out until after App Review.

## F-Droid Build Notes

F-Droid metadata lives in `fdroid/com.nfcarchiver.nfc_archiver.yml` (a reference mirror); the authoritative copy is in [fdroiddata](https://gitlab.com/fdroid/fdroiddata).

**Routine version bumps need no manual MR.** `AutoUpdateMode: Version` + `UpdateCheckMode: Tags` + `UpdateCheckData` mean F-Droid's bot watches git tags, reads the version from `pubspec.yaml`, and generates the `Builds:` entry itself — pushing a `vX.Y.Z` tag is the whole trigger. An MR is needed only when the **build recipe** changes (a new prebuild step, system package, JDK/SDK/Flutter pinning, `srclibs`/`rm`/`scandelete`). See `docs/RELEASING.md`.

Key gotchas:

- **`compileSdk` is 36** — it was pinned to 34 for a JDK 21 `jlink`/`JdkImageTransform` bug on F-Droid's builder. That pin is no longer needed: the buildserver image is now `buildserver-trixie`, the recipe installs JDK 17 from Bookworm and sets `JAVA_HOME` to it, and published F-Droid Flutter apps build on `compileSdk 36`. `android/build.gradle` also forces every **plugin subproject** to the same `compileSdk`; plugins pinning an older one fail `checkDebugAarMetadata` once a transitive AndroidX artifact requires a newer API level.
- **`flutter pub get --enforce-lockfile`** — F-Droid's canonical Flutter template (`templates/build-flutter.yml` in fdroiddata) uses this flag, so `pubspec.lock` must be consistent with the pinned Flutter SDK. CI passes the same flag; without it CI silently re-resolves and cannot catch the drift, which is how a broken lockfile reached F-Droid unnoticed (issue #63).
- **AGP stays on the 8.x line** — Flutter 3.44 requires AGP >= 8.6.0, but AGP 9+ reads only the new DSL, which `android/app/build.gradle` (Groovy) does not use. `android/gradle.properties` carries `android.newDsl=false` and `android.builtInKotlin=false` for the same reason.
- **Flutter version is pinned from the release workflow** — `prebuild` extracts `FLUTTER_VERSION` from `.github/workflows/release.yml` via `sed`. If you rename/restructure the workflow, the F-Droid build will break. The `sed` must also match exactly one line — keep a single `FLUTTER_VERSION: 'X.Y.Z'` in that file.
- **`pub get` runs in `prebuild`, not `build`** — F-Droid scans dependencies between prebuild and build. `.pub-cache` is in `scandelete` (deleted after scanning). Any build step that depends on `.pub-cache` must set `PUB_CACHE=$(pwd)/.pub-cache`.
- **Categories** — F-Droid does not accept `Utility`. Current categories: `Connectivity`, `System`.
- **Commit reference** — Use full commit SHA in the `commit:` field, not tag references.
- **`rewritemeta` formatting** — Run `rewritemeta com.nfcarchiver.nfc_archiver` in the fdroiddata repo before submitting. It enforces field ordering and line formatting. `sudo:` must come after `commit:`, and compound shell commands (like `echo ... > file`) must be on a single line.
- **`UpdateCheckData`** — Regex pattern `pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+` extracts versionCode and versionName from `pubspec.yaml`. The `version:` field format in pubspec must remain `X.Y.Z+N`.
