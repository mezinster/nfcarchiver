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

Uses Flutter's `gen-l10n` with ARB files in `lib/l10n/`. Supported: English (`app_en.arb`), Russian (`app_ru.arb`). Run `flutter gen-l10n` after modifying ARB files.
