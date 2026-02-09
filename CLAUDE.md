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
- **`archive/`** — `ArchiveNotifier` uses sealed class states (`ArchiveInitial` → `ArchiveFileSelected` → `ArchiveConfiguring` → `ArchivePreparing` → `ArchiveReady` → `ArchiveWriting` → `ArchiveComplete`). Supports `rechunkForDetectedCapacity()` when tag is smaller than expected.
- **`restore/`** — `RestoreNotifier` with states for scanning, collecting chunks into `RestoreSession` by UUID, handling CRC errors with rescan capability.

### State Management

Riverpod with `StateNotifier` pattern using sealed classes for type-safe state transitions:
- `archiveProvider` — Archive creation workflow
- `restoreProvider` — Restore/scanning workflow

### NFAR Format

28-byte header. Flags byte: bit 0 = GZIP, bit 1 = AES-256-GCM. Archive ID is UUID v4 (16 bytes) for grouping chunks. Max 65535 chunks per archive. Chunks validated with CRC32 and can be scanned in any order.

### Localization

Uses Flutter's `gen-l10n` with ARB files in `lib/l10n/`. Supported: English (`app_en.arb`), Russian (`app_ru.arb`), Turkish (`app_tr.arb`), Ukrainian (`app_uk.arb`), Georgian (`app_ka.arb`). Run `flutter gen-l10n` after modifying ARB files.

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

## F-Droid Build Notes

F-Droid metadata lives in `fdroid/com.nfcarchiver.nfc_archiver.yml` (local copy) and is submitted via MR to [fdroiddata](https://gitlab.com/fdroid/fdroiddata). Key gotchas for future updates:

- **`compileSdk` must stay at 34** — F-Droid's build server has a JDK 21 `jlink`/`JdkImageTransform` bug with SDK 35. Do not bump `compileSdk` unless F-Droid upgrades their JDK or the bug is fixed. The build also installs JDK 17 from Debian Bookworm as a workaround.
- **Flutter version is pinned from the release workflow** — `prebuild` extracts `FLUTTER_VERSION` from `.github/workflows/release.yml` via `sed`. If you rename/restructure the workflow, the F-Droid build will break.
- **`pub get` runs in `prebuild`, not `build`** — F-Droid scans dependencies between prebuild and build. `.pub-cache` is in `scandelete` (deleted after scanning). Any build step that depends on `.pub-cache` must set `PUB_CACHE=$(pwd)/.pub-cache`.
- **Categories** — F-Droid does not accept `Utility`. Current categories: `Connectivity`, `System`.
- **Commit reference** — Use full commit SHA in the `commit:` field, not tag references.
- **`rewritemeta` formatting** — Run `rewritemeta com.nfcarchiver.nfc_archiver` in the fdroiddata repo before submitting. It enforces field ordering and line formatting. `sudo:` must come after `commit:`, and compound shell commands (like `echo ... > file`) must be on a single line.
- **`UpdateCheckData`** — Regex pattern `pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+` extracts versionCode and versionName from `pubspec.yaml`. The `version:` field format in pubspec must remain `X.Y.Z+N`.
