# Diagnostics log + readable scan errors — design

Date: 2026-11-11 · Branch: `feat/diagnostics-log`

## Why

On an iPhone (TestFlight build 1.2.1+19) the maintainer scanned a formatted
but empty tag in a coffee shop. The scan screen filled with a wall of text —
`Failed to read tag: PlatformException(Error Domain=NFCError Code=403 "NDEF tag
does not contain any NDEF message" …, NFCError, Stacktrace: ["0 Runner
0x…", …])` — that was gone before it could be read, and nothing kept it.

Two problems, both fixed in this branch:

1. **The error itself.** An empty tag is not an error at all; it should read as
   "this tag has no archive data". And no screen should ever show a raw
   exception or a native stack.
2. **Nothing remembers what happened.** TestFlight only reports real process
   crashes. Dart exceptions are caught by Flutter and never become crash
   reports, so every failure a tester can hit is invisible. The maintainer
   wants to read, after the fact, every error the user saw *and the actions
   that led to it* — on the phone, and as a file they can send.

## Goals

- Every error the user is shown is also recorded, with the full technical
  detail (exception text, Dart stack, native stack where the platform gives
  one).
- A trail of preceding actions (screens opened, sessions armed, tags
  discovered, chunks read/written, state transitions) is recorded with
  timestamps, so an error can be read in context.
- The record survives an app restart and a crash.
- A **Diagnostics log** screen shows it on the phone; **Share** sends it as a
  `.txt` file; **Clear** empties it.
- Screens show short, translated messages; raw detail lives only in the log.
- An empty formatted tag on iOS (Core NFC `NFCError` 403) is treated exactly
  like an empty tag on Android: "no archive data", not a failure.

## Non-goals

- No network. Nothing leaves the phone unless the user shares it. No Sentry,
  Crashlytics or any SDK. `PrivacyInfo.xcprivacy` and the App Store privacy
  answers stay as they are (no collected data).
- No native (Swift/Kotlin) crash capture — a hard native crash is already
  covered by TestFlight / Play crash reporting.
- No changes to the web app.
- No grouped/card log UI (option B in the mockups was rejected).

## Anti-goals (would be a failure even if it "works")

- A shared log that contains the user's file contents, file names or
  passwords. Testers send this file to the developer; it must be safe to send.
- A raw `PlatformException`/stack anywhere on screen after this branch.
- Error handlers that swallow errors in debug builds (developers must still
  see the red screen / console output).
- Unbounded log growth.

## Decisions taken in conversation

- **Both** an in-app Log screen and Share. (maintainer)
- **Log screen layout A — raw lines** (mockup accepted): one greppable line per
  entry, exactly the text that gets shared; under an error its detail/stack is
  wrapped beneath the line. Filter chips **All** / **Warnings & errors**. App
  bar actions: Share, Clear. (maintainer)
- **Scan screen after the fix** (mockup accepted):
  - a tag without our data → neutral info card **"No NFC Archiver data on
    this tag"** (maintainer, after the builder check). One message for blank
    tags *and* tags holding something else (URL stickers, transit cards,
    foreign Mifare cards) — the app does not tell these apart, so the
    mockup's "formatted but empty" wording is dropped and `TagCodec`'s
    `Chunk?` return type stays as it is;
  - any other read failure → error card "Couldn't read this tag" — hold it
    still and try again — with a **Details** button that opens the Log screen.
- **The non-NFAR / empty-tag fix ships in this branch.** (maintainer)
- **Both platforms, iOS and Android.** (maintainer) ADB/logcat helps only a
  developer with a cable; F-Droid/Play/APK testers have no such thing, and
  logcat's history is short. Console mirroring stays, so ADB keeps working.
  Only the 403 fix is iOS-specific (a Core NFC quirk); Android's
  `PlatformException` text can also carry a Java stack, so the screen-side
  fix applies to both.

## Evidence for the 403 fix

From `nfc_manager-4.2.1`:

- `ios/.../Pigeon.swift:51-55` — any non-Pigeon Swift error is sent to Dart as
  `[code: "\(error)", message: "\(type(of: error))", details: "Stacktrace:
  \(Thread.callStackSymbols)"]`. So on Dart's side the `PlatformException` has
  `code` = `Error Domain=NFCError Code=403 "NDEF tag does not contain any NDEF
  message" UserInfo={…}`, `message` = `NFCError`, `details` = the Swift stack.
  The maintainer's screenshot (IMG_2931) matches this exactly.
- `ios/.../NfcManagerPlugin.swift:767-768` — the plugin's own tag-discovery
  path already treats NSError code 403 as "no message". Its explicit
  `ndefReadNdef` (line 121) does not, and that is what `IosNdefIO.read()`
  (`lib/features/nfc/domain/ndef_io.dart:79`) calls.

Fix location: `IosNdefIO.read()` catches a `PlatformException` whose `code`
contains `Domain=NFCError Code=403` and returns the empty message (the same
thing `ndefMessageOrEmpty` does for `null`). The rest of the pipeline then
already produces "no archive data". Pin the match with a unit test using the
literal strings above.

## Design

### 1. Log persistence (`lib/core/log/`)

The app already has `Logger` (`lib/core/log/logger.dart`): an in-memory ring
buffer of 2000 entries plus console mirroring, written explicitly so "a Log
screen (and copy/share for bug reports) can be added later without
re-instrumenting anything". Build on it; don't replace it.

- `LogEntry` gains an optional multi-line `detail` (exception text + stack).
  `format()` stays one line; a new form for files/screen appends `detail`
  indented on following lines.
- A file sink appends formatted entries to
  `getApplicationSupportDirectory()/logs/diagnostics.log` (app-private, not
  backed up to user-visible storage; `path_provider` is already a dependency).
- **Only `info` and above are persisted.** `debug` stays in memory/console as
  today, because debug entries carry Chameleon frame hex dumps
  (`ble_chameleon_device.dart:233-270`), i.e. card contents.
- **Durability:** buffer writes and flush at least every ~2 s, immediately on
  `warn`/`error`, and on app lifecycle `paused`/`detached`. An error must be
  on disk before a crash that follows it.
- **Bound:** rotate at ~512 KB to `diagnostics.1.log`, keeping one previous
  file. Share/screen read both, oldest first.
- **Session header:** each app start writes a line with app version + build
  (`PackageInfo`), platform and `Platform.operatingSystemVersion`, active
  locale. No device identifiers.
- File I/O failures must never throw into callers; the logger degrades to
  memory-only.
- Tests: injectable directory/clock so the sink is tested without
  `path_provider` (follow the `FileActionsService` injection style).

### 2. Capturing errors

- **Uncaught:** in `main()` install `FlutterError.onError` (log at `error`
  with `details.exceptionAsString()` + stack, then still call
  `FlutterError.presentError` so debug behaviour is unchanged) and
  `PlatformDispatcher.instance.onError` (log, return `true`).
- **Shown errors:** every place that turns an exception into user-visible text
  must instead (a) log the exception with its stack and (b) show a short
  translated message. Known sites (from `grep e.toString()`):
  - `nfc_repository.dart:259` (`Failed to read tag: $e`), `:467-468` (write),
    `:552`, `:608`
  - `nfc_provider.dart:159`, `:214`
  - `scan_screen.dart:114`
  - `restore_provider.dart:278`, and `restore_repository.dart:97`
    (`Failed to assemble chunks: $e`)
  - `archive_provider.dart:273`
  - `file_manager_provider.dart:57`
  - `file_picker_screen.dart:282` (`errorSelectingFile(e.toString())`)
  - `chameleon_reader.dart:300` (`onError(e.toString())`)
  - `reader_provider.dart:97`
  The builder should re-grep for others (`$e`, `'$error'`, `.toString()` into
  state/snackbars) rather than trust this list.
- **Message shape:** today error messages travel as English `String`s through
  `onError(String)` / `NfcSessionError(message)` / `scanError(String)` and
  some are hardcoded English (`messageFor()` in `ndef_availability.dart`,
  `'Tag does not contain valid archive data'`). Replace the string with a
  small typed failure (e.g. a `kind` enum: noArchiveData, readFailed,
  writeFailed, notNdef, mifareUnsupported, tagLost, unknown…) that the screen
  maps to an `AppLocalizations` string. How far to push this (all paths vs.
  the scan/write paths first) is the builder's call, as long as no raw
  exception reaches the screen.
- **Native stacks** (`PlatformException.details` starting `Stacktrace:`) are
  kept in the log entry's `detail`, never in a message.

### 3. Breadcrumbs (preceding actions)

Existing `nfc.read`/`reader`/`ble` info entries already cover scanning. Add,
at `info`:

- route changes, via a `NavigatorObserver` on the `GoRouter` (`[nav] open
  /restore/scan`);
- archive and restore state transitions (`ArchiveNotifier`,
  `RestoreNotifier`): state class name plus safe numbers (chunk index/total,
  sizes, tag type, compression/encryption flags as booleans);
- write session start/success/failure in `nfc_repository` where missing;
- reader switches (phone ↔ Chameleon).

**Never log:** file names, file contents or payload bytes at `info`+, the
encryption password, restored text. Archive IDs and tag UIDs are allowed (they
identify cards, not content, and are needed to debug multi-card issues).
The Chameleon write-verification failure logs only the block number and the
first differing byte at `error`; the two 16-byte hex dumps are `debug`-only
(memory/console).

### 4. Log screen

- Route `/diagnostics` (GoRouter, in `lib/app.dart`). Reached from:
  - the About dialog (`home_screen.dart:156`): a "Diagnostics log" button next
    to "Privacy policy";
  - the **Details** button on scan/write error cards.
- Layout A from the mockup: monospace lines (time, level, `[scope]`, message,
  `key=value` data), errors in the error colour with `detail` wrapped and
  indented beneath; newest at the bottom, opens scrolled to the bottom (or to
  the entry when opened from Details — nice-to-have; bottom is acceptable).
  Selectable text.
- Filter chips: **All** / **Warnings & errors**.
- App bar: **Share** — writes a temporary `nfc-archiver-log-<timestamp>.txt`
  (previous + current file, plus a header line with version/platform) and
  shares it through `FileActionsService.shareFile` (gives it `text/plain`,
  per the share_plus rules in CLAUDE.md). **Clear** — confirm dialog, then
  truncates files and memory.
- Empty state text when there is nothing logged.

### 5. Localization

All new strings in `app_en.arb` and all six translations (ru, tr, uk, ka, pl,
be), then `flutter gen-l10n`. Log *contents* stay English (as in the web app).

## Testing

- Unit: 403 → empty message (exact Core NFC strings); other
  `PlatformException`s still throw; file sink rotation, level filter, flush on
  error, header line, failure-tolerance; `format` with detail; typed failure →
  l10n mapping; no raw exception text in screen state for each converted site.
- Widget: Log screen renders entries, filter chips, Share invokes
  `FileActionsService`, Clear confirms and empties; scan screen shows the two
  card variants from the mockup.
- `flutter analyze` and the full `flutter test` suite stay green.
- Hardware (owed after merge, cannot be done in CI): iPhone — blank NTAG shows
  the "no archive data" card and the scan continues; a log is shared to
  Telegram and opens as text. Android — same with a blank tag.

## Calls made after the builder check (author's calls, not discussed)

- **A tag without our data is not a scan error.** The iOS sheet still ends
  with ✕ (`endTag`/`end(problem: true)` semantics unchanged, as shown in the
  accepted mockup), but the repository reports it through its own path
  (typed failure kind `noArchiveData`, or a dedicated callback) and the scan
  screen does **not** count it toward `_consecutiveErrors` / `_errorLimit`
  (`scan_screen.dart:50-61`). That limit exists to stop runaway Chameleon
  loops; every phone-radio blank tag is a deliberate tap.
- **Mifare and the Chameleon get the same message.** Android's phone radio
  already reaches the same `null` for a non-NFAR Mifare card
  (`mifare_tag_codec.dart:52`). iPhone's phone radio cannot see Mifare Classic
  at all, so it keeps its existing `mifareUnsupported` message (now
  translated). The Chameleon currently skips a non-NFAR card **silently**
  (`chameleon_reader.dart:138-140`, debug-level log); it will instead surface
  the same neutral "No NFC Archiver data on this tag" (not counted as an
  error, no restart — its poll loop keeps running) and log it at `info`. The
  poll loop may re-detect a card left on the reader; showing the same banner
  again is harmless, but the info entry should not repeat for the same UID
  back-to-back (log once per UID until a different card or no card is seen).
- **Write screen:** no new card. Write errors stay in the existing SnackBar
  (`write_progress_screen.dart:95-100`), with the translated short message and
  a **Details** `SnackBarAction` that opens the Log screen.
- **Privacy policy is updated in this branch.** `site-docs/docs/*/privacy.md`
  ("Diagnostic logs", en line 48-50, all seven languages) currently says the
  log is in memory and gone when the app closes — false after this change. New
  text: the log is kept in a file on the device, rotated to a small size, never
  sent anywhere, shared only by the user, and cleared from the Log screen. The
  docs deploy (`deploy-docs.yml`) must go out before the app release that
  contains this feature reaches users. `check_site.py` must pass.

## Left to the builder

- Exact typed-failure taxonomy and how far to convert in this branch.
- Flush timer value, rotation size, file naming details.
- Whether Details scrolls to the specific entry.
- Exact copy of the new strings (keep it short; the mockup wording is a guide).
