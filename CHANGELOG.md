# Changelog

All notable changes to NFC Archiver will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.7] - 2026-02-17

### Added
- File manager screen for viewing, sharing, and deleting restored files
- Storage indicator on home screen showing file count and total size
- Delete file button on restore complete screen (files and text notes)
- Localized file management strings for all 5 languages (EN, RU, TR, UK, KA)

### Changed
- Home screen body is now scrollable to support smaller viewports
- Extracted shared `formatFileSize()` utility replacing 3 duplicated methods
- iOS build in release workflow is now non-blocking (`continue-on-error`)

## [1.0.6] - 2026-02-01

### Added
- F-Droid publishing metadata (fastlane structure, store listing images)
- MIT LICENSE file
- F-Droid store listing: icon, feature graphic, and 6 phone screenshots

### Changed
- Lowered compileSdk to 34 for F-Droid JDK 21 compatibility
- Added Gradle `afterEvaluate` block to override compileSdk for plugin subprojects

## [1.0.4] - 2026-01-27

### Changed
- Release workflow now supports branch selection via `workflow_dispatch` input
- Workflow run name shows version and branch in Actions UI
- Added release notes input field for custom changelog entries
- Updated SDK version

## [1.0.3] - 2026-01-26

### Added
- Textarea feature to send text messages over NFC tags
- Turkish, Ukrainian, and Georgian translations
- Internationalization support with English and Russian languages
- Language selector in app bar with flag icons
- Persistent language preference
- GitHub Actions CI/CD (analyze, test, debug builds, release workflow)
- Dependabot for automated dependency updates
- Copyright footer
- Original filename preserved in archive metadata

### Fixed
- Critical GCM encryption bug: `cipher.getOutputSize()` over-estimated buffer size, causing garbage bytes to corrupt authentication tag
- NFC `Map<Object?, Object?>` type cast error on Android 16
- Password handling: trim whitespace, disable autocorrect/suggestions on password fields
- Dart SDK version constraint lowered to `^3.5.0` for Flutter 3.24.0 compatibility
- "Try Again" navigation was routing to wrong screen

### Improved
- Restore error handling: retry password without rescanning, rescan only corrupted chunks
- Write cooldown (2s) to prevent NFC re-read after write
- Adaptive chunk sizing that detects actual tag NDEF capacity
- Decryption password field with character counter and detailed error messages
- NDEF overhead calculation corrected (was 10 bytes, now 44 bytes)

## [1.0.0] - 2026-01-26

### Added
- Initial release
- Create archives from any file type
- Split files across multiple NFC tags (NTAG213/215/216, MIFARE Ultralight)
- Restore files by scanning tags in any order
- GZIP compression support
- AES-256-GCM encryption with password protection
- NFAR binary format with CRC32 validation
- Adaptive chunk sizing based on detected tag capacity
- Dark/light theme support following system preference

### Technical
- Flutter 3.24+ with Dart 3.5+
- Riverpod state management
- GoRouter navigation
- NDEF formatting for NFC tags
