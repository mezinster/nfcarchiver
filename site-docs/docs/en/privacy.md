# Privacy policy

**NFC Archiver** · Last updated: 7 November 2026

## In short

NFC Archiver works entirely offline. It does not collect or send any personal data, and it contains no analytics, advertising or tracking. It uses NFC, Bluetooth (only to talk to a Chameleon Ultra reader that you own) and the files you pick yourself.

## Data collection

**We do not collect any data.** Specifically:

- No personal information is collected.
- No usage analytics or tracking.
- No crash reports are sent anywhere.
- No cookies or identifiers.
- No advertising or marketing data.

## NFC

NFC is used only to read and write data on physical NFC tags that you hold near your phone. All NFC operations are local; nothing is sent over the network.

## Bluetooth

Bluetooth is used only to connect to a Chameleon Ultra reader that you own, so that the app can read and write Mifare Classic cards through it. The connection is local, between your phone and the reader. No data leaves your device because of it, and the app does not use Bluetooth to determine your location.

## Files

Files you choose to archive are processed entirely on your device. A file is:

- read from your device through the system file picker;
- optionally compressed (GZIP) on the device;
- optionally encrypted (AES-256-GCM) on the device;
- split into chunks and written to NFC tags.

No file data is ever uploaded, shared or sent to any server. Files you restore are saved in the app's private storage, and leave it only when you choose Open, Save to device or Share. An unfinished restore (the chunks scanned so far) is kept in the app's private storage until you finish it or delete it from the list.

## Encryption

When you turn on encryption:

- your password is used on the device to derive the encryption key (PBKDF2);
- your password is never stored, logged or transmitted;
- encryption and decryption happen entirely on your device.

If you forget the password, nobody can recover the file, including us.

## Diagnostic logs

The app keeps a diagnostic log on your device: what it did and any errors it hit, so problems can be investigated. It is stored in a small file that is rotated automatically, and it never contains your files, file names or passwords. It is never sent anywhere. It leaves your device only if you share it yourself — from **About → Diagnostics log**, where you can also clear it at any time.

## Third-party services

NFC Archiver uses **no third-party services**: no analytics, no cloud storage, no remote servers and no social media integrations.

## Permissions

Every permission the app declares, and what it is for:

**Android**

- **NFC** (`NFC`): to read and write NFC tags.
- **Bluetooth** (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `BLUETOOTH`, `BLUETOOTH_ADMIN` on older Android versions): only to find and connect to a Chameleon Ultra reader that you own.
- **Storage** (`READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`): on older Android versions only, to read the files you pick and to save restored files. On current versions, files are chosen through the system file picker.

**iPhone**

- **NFC** (`NFCReaderUsageDescription`): to read and write NFC tags.
- **Bluetooth** (`NSBluetoothAlwaysUsageDescription`): only to connect to a Chameleon Ultra reader that you own.

## This website

This documentation site sets no cookies, runs no analytics and loads no third-party fonts or scripts. Its search runs locally in your browser.

## Children's privacy

The app collects no data from anyone, including children.

## Changes to this policy

If this policy changes, the new text will be published on this page and the date above updated.

## Contact

Questions about this policy: [support@nfcarchiver.com](mailto:support@nfcarchiver.com).
