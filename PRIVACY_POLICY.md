# Privacy Policy

**NFC Archiver**
**Last updated: February 2026**

## Overview

NFC Archiver is designed with privacy as a core principle. The app operates entirely offline and does not collect, transmit, or store any personal data.

## Data Collection

**We do not collect any data.** Specifically:

- No personal information is collected
- No usage analytics or tracking
- No crash reports sent externally
- No cookies or identifiers
- No advertising or marketing data

## NFC Access

NFC functionality is used exclusively for reading and writing data to physical NFC tags held near your device. All NFC operations are local — no data is transmitted over the network.

## File Processing

Files you select for archiving are processed entirely on your device. File data is:

- Read from local storage
- Optionally compressed (GZIP) on-device
- Optionally encrypted (AES-256-GCM) on-device
- Split into chunks and written to NFC tags

No file data is ever uploaded, shared, or transmitted to any server.

## Encryption

When you enable encryption:

- Your password is used locally to derive an encryption key (PBKDF2)
- Your password is never stored, logged, or transmitted
- Encryption and decryption happen entirely on your device

## Third-Party Services

NFC Archiver uses **no third-party services**, including:

- No analytics services
- No cloud storage
- No remote servers
- No social media integrations

## Permissions

The app requests only the permissions necessary for its core functionality:

- **NFC**: To read and write NFC tags
- **Storage/Files**: To access files you choose to archive or restore

## Children's Privacy

The app does not collect any data from anyone, including children.

## Changes to This Policy

If this policy is updated, the changes will be reflected in the app and this document.

## Contact

If you have questions about this privacy policy, please open an issue on the project's GitHub repository.
