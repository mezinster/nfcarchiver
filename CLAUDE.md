# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
flutter pub get

# Run on connected device
flutter run

# Analyze code for errors
flutter analyze

# Run tests
flutter test

# Run single test file
flutter test test/widget_test.dart

# Build APK (Android)
flutter build apk

# Build iOS (requires macOS + Xcode)
flutter build ios
```

## Architecture

This is a Flutter app for distributed file storage across NFC tags using the NFAR (NFC Archive) binary format.

### Data Flow

**Archive flow:** File → (compress) → (encrypt) → chunk into NFAR packets → write to NFC tags

**Restore flow:** Scan NFC tags in any order → collect chunks by Archive ID → assemble → (decrypt) → (decompress) → File

### Core Layer (`lib/core/`)

- **`constants/nfar_format.dart`** — NFAR v1 binary format specification (28-byte header + payload + CRC32). All multi-byte values are big-endian.
- **`models/chunk.dart`** — `Chunk` class with `toBytes()`/`fromBytes()` serialization
- **`services/chunker_service.dart`** — Splits data into chunks, reassembles with CRC32 validation
- **`services/encryption_service.dart`** — AES-256-GCM encryption with PBKDF2 key derivation (salt+IV prepended to ciphertext)
- **`services/compression_service.dart`** — GZIP compression wrapper

### Features Layer (`lib/features/`)

Each feature follows: `data/` (repository) → `presentation/providers/` (Riverpod state) → `presentation/screens/`

- **`nfc/`** — NFC abstraction over `nfc_manager` package. `NdefFormatter` converts Chunk↔NDEF.
- **`archive/`** — File selection, settings, chunk writing workflow
- **`restore/`** — Tag scanning, chunk collection by UUID, assembly

### State Management

Uses Riverpod with `StateNotifier` pattern. Key providers:
- `nfcSessionProvider` — NFC read/write session state
- `archiveProvider` — Archive creation workflow state
- `restoreProvider` — Restore/scanning workflow state

### NFAR Format Notes

Header is 28 bytes. Flags byte: bit 0 = GZIP compressed, bit 1 = AES-256-GCM encrypted. Archive ID is UUID v4 (16 bytes) — used to group chunks from same archive during restore. Chunks can be scanned in any order.
