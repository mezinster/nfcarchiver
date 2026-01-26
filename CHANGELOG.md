# Changelog

All notable changes to NFC Archiver will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Internationalization support with English and Russian languages
- Language selector in app bar with flag icons
- Persistent language preference

## [1.0.0] - 2024-01-26

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
