# Diagnostics Log + Readable Scan Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the app's existing structured log to a bounded on-device file, show it on a Diagnostics log screen with Share/Clear, record every user-visible error with full detail, and replace raw exception text on screen (including the iOS empty-tag `NFCError 403` wall of text) with short translated messages.

**Architecture:** `Logger` (`lib/core/log/logger.dart`) stays the single entry point; it gains a `detail` field, a `report()` helper and a listener hook. A new `DiagnosticsFile` sink persists `info`+ entries. NFC errors stop travelling as English strings: `CardReader.onError` carries a typed `NfcFailure`, mapped to `AppLocalizations` at the screen. Non-NFC `catch (e)` sites log via `log.report` and show a generic localized message.

**Tech Stack:** Flutter (version pinned in `.github/workflows/ci.yml`), Riverpod `StateNotifier`, go_router 18, `path_provider`, `package_info_plus`, `share_plus` via `FileActionsService`, gen-l10n ARB files.

**Spec:** `docs/superpowers/specs/2026-11-11-diagnostics-log-design.md`

## Global Constraints

- Both platforms (iOS and Android). Console mirroring (`debugPrint` + `developer.log`) stays unchanged so ADB/`flutter run` keep working.
- No network, no new SDKs, no new pub dependencies. `ios/Runner/PrivacyInfo.xcprivacy` unchanged.
- Only `info`, `warn`, `error` are persisted; `debug` stays memory/console only.
- File: `getApplicationSupportDirectory()/logs/diagnostics.log`, rotate at 512 KB (`512 * 1024`) to `diagnostics.1.log`, one previous file kept.
- Flush: at least every 2 s, immediately on `warn`/`error`, and on lifecycle `paused`/`detached`.
- Never log at `info`+: file names, file contents, payload bytes, passwords, restored text. Archive IDs and tag UIDs are allowed. Accepted exception: `chameleon_reader.dart:442` verification-failure hex.
- Log contents are English. All new UI strings go in `lib/l10n/app_en.arb` and the 6 translations (`ru tr uk ka pl be`), then `flutter gen-l10n`.
- No raw exception, `PlatformException` text or stack may reach any screen.
- Debug behaviour preserved: `FlutterError.onError` must still call `FlutterError.presentError`.
- Shared file goes through `FileActionsService.shareFile` (MIME from extension → `text/plain`).
- Commands: `flutter analyze` clean; `flutter test` green after every task.

## Review Focus

1. **Disk failure** (support dir missing, write throws, disk full) → logger keeps working in memory, nothing throws into callers. *Pinned in Task 2.*
2. **Re-entrancy**: an exception thrown while writing a log entry from inside `FlutterError.onError` must not recurse or crash. *Pinned in Task 3.*
3. **Huge detail** (a 40-frame Swift stack, or an exception whose `toString()` is megabytes) → detail capped at 8 KB per entry, marked truncated. *Pinned in Task 1.*
4. **Clear racing a pending flush** → cleared lines never reappear; Share of an empty log produces a file with just the header. *Pinned in Task 2.*
5. **Password leakage via state-transition breadcrumbs** → `ArchiveNotifier` breadcrumbs never contain the password or file name. *Pinned in Task 8.*

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/core/log/logger.dart` (modify) | `LogEntry.detail`, `formatFull()`, `Logger.report()`, `errorDetail()`, listeners |
| `lib/core/log/diagnostics_file.dart` (new) | Buffered, rotating, failure-tolerant file sink; read/clear/export |
| `lib/core/log/diagnostics.dart` (new) | Startup wiring: error hooks, session header, lifecycle flush, provider |
| `lib/core/log/log_navigator_observer.dart` (new) | Route breadcrumbs |
| `lib/features/nfc/domain/nfc_failure.dart` (new) | `NfcFailureKind`, `NfcFailure` |
| `lib/features/nfc/presentation/nfc_failure_text.dart` (new) | `NfcFailure` → localized string, `isNeutral` |
| `lib/features/nfc/domain/ndef_io.dart` (modify) | iOS 403 → empty message |
| `lib/features/diagnostics/presentation/diagnostics_screen.dart` (new) | Log screen (layout A), Share, Clear |
| `site-docs/docs/*/privacy.md` (modify ×7) | "Diagnostic logs" section |

---

### Task 1: Logger detail, `report()`, listeners

**Files:**
- Modify: `lib/core/log/logger.dart`
- Test: `test/logger_test.dart`

**Interfaces:**
- Produces:
  - `LogEntry({..., String? detail})`, `String LogEntry.formatFull()` — `format()` line, then each `detail` line prefixed with 4 spaces.
  - `static const int Logger.maxDetailChars = 8192`
  - `void Logger.report(String scope, String message, Object error, [StackTrace? stack, Map<String, Object?>? data])` — logs at `error` with `detail: errorDetail(error, stack)`.
  - `String errorDetail(Object error, StackTrace? stack)` (top-level) — for `PlatformException`: lines `code: …`, `message: …`, `details: …`; otherwise `error.toString()`; then `stack` if non-null. Capped to `maxDetailChars`, ending with `… [truncated]` when cut.
  - `void Logger.addListener(void Function(LogEntry) l)`, `void Logger.removeListener(...)` — called for every recorded entry (after level filter). A listener that throws is caught and ignored.
  - existing `warn`/`error`/etc gain optional named `{String? detail}`.

- [ ] **Step 1: Write failing tests** in `test/logger_test.dart`:
  - `report() records an error with PlatformException fields on separate lines` — `log.report('nfc.read', 'read failed', PlatformException(code: 'Error Domain=NFCError Code=403 "x"', message: 'NFCError', details: 'Stacktrace: ["0 Runner"]'))`; expect level `error`, `detail` contains `code: Error Domain=NFCError Code=403`, `message: NFCError`, `details: Stacktrace:`.
  - `formatFull indents detail under the line` — `formatFull().split('\n')[1]` starts with `'    '`; `format()` contains no `\n`.
  - `detail is capped at maxDetailChars` — error whose `toString()` is `'x' * 100000`; `detail!.length <= Logger.maxDetailChars + 20`, ends with `[truncated]`.
  - `listeners receive entries after the level filter and a throwing listener is ignored` — add a throwing listener and a collecting one; `minLevel = info`; `debug` + `info`; collector has exactly the info entry; no exception escapes.
- [ ] **Step 2: Run** `flutter test test/logger_test.dart` — expect FAIL (undefined `report`, `detail`).
- [ ] **Step 3: Implement** in `logger.dart`. Console mirroring prints `formatFull()`.
- [ ] **Step 4: Run** `flutter test test/logger_test.dart` — PASS.
- [ ] **Step 5: Commit** `feat(log): entry detail, report() and listeners`

### Task 2: `DiagnosticsFile` sink

**Files:**
- Create: `lib/core/log/diagnostics_file.dart`
- Test: `test/diagnostics_file_test.dart`

**Interfaces:**
- Consumes: `LogEntry`, `formatFull()`, `LogLevel` (Task 1).
- Produces:
  ```dart
  class DiagnosticsFile {
    DiagnosticsFile({required Directory dir, int maxBytes = 512 * 1024,
        Duration flushEvery = const Duration(seconds: 2)});
    static const fileName = 'diagnostics.log';
    static const previousFileName = 'diagnostics.1.log';
    void add(LogEntry e);            // drops debug; schedules/forces flush
    void writeLine(String line);     // raw line (session header), flushed with next flush
    Future<void> flush();
    Future<String> readAll();        // previous file then current, after a flush
    Future<void> clear();            // drops buffer + deletes both files
    Future<File> exportTo(Directory tmp, {required DateTime now, required String header});
                                     // nfc-archiver-log-<yyyyMMdd-HHmmss>.txt = header + '\n' + readAll()
    bool get degraded;               // true after any I/O failure; sink then no-ops
  }
  ```
  Writes are serialized through one `Future` chain (no interleaving). Rotation is checked before each append: if current length + pending ≥ `maxBytes`, rename current → previous (replacing it). Every I/O call is wrapped; failure sets `degraded` and never throws.

- [ ] **Step 1: Write failing tests** using `Directory.systemTemp.createTempSync()`:
  - `debug entries are not persisted; info+ are`
  - `an error entry is on disk without waiting for the timer` — `flushEvery: const Duration(hours: 1)`; `add(error)`; then only `await pumpEventQueue()` (no explicit `flush()`); `File('<dir>/diagnostics.log').readAsStringSync()` contains the line. (`warn`/`error` trigger an immediate flush.)
  - `rotates at maxBytes keeping one previous file` — `maxBytes: 1024`, add 100 info entries, flush; both files exist, `diagnostics.log` < 1024 + one entry, no `diagnostics.2.log`; `readAll()` lines are in seq order.
  - `clear while a flush is pending leaves nothing behind` — add 5 info, `clear()` without flushing, then `flush()`; `readAll()` is empty.
  - `exportTo writes header then content, header alone when empty` — filename matches `RegExp(r'^nfc-archiver-log-\d{8}-\d{6}\.txt$')`.
  - `an unwritable directory degrades instead of throwing` — `dir` = a path under a regular file (e.g. `File(tmp/'f')..createSync()` then `Directory('${f.path}/logs')`); `add(error)`, `await flush()` complete normally; `degraded == true`.
- [ ] **Step 2: Run** `flutter test test/diagnostics_file_test.dart` — FAIL.
- [ ] **Step 3: Implement** `DiagnosticsFile`. Timer: a single `Timer` armed on first buffered `info`, cancelled by flush.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(log): rotating on-device diagnostics file`

### Task 3: Startup wiring and error hooks

**Files:**
- Create: `lib/core/log/diagnostics.dart`
- Modify: `lib/main.dart`
- Test: `test/diagnostics_hooks_test.dart`

**Interfaces:**
- Consumes: `Logger.addListener`, `Logger.report`, `DiagnosticsFile`.
- Produces:
  - `final diagnosticsFileProvider = Provider<DiagnosticsFile?>((ref) => null);` — overridden in `main()`; `null` means unavailable (tests, or support dir failed).
  - `void installErrorHooks(Logger logger)` — sets `FlutterError.onError` (logger.report('flutter', 'Uncaught Flutter error', details.exception, details.stack) then `FlutterError.presentError(details)`) and `PlatformDispatcher.instance.onError` (report `'platform'`, `'Uncaught async error'`; return `true`). A guard flag drops re-entrant calls: if reporting itself throws, swallow.
  - `String sessionHeader({required String version, required String build, required String os, required String locale})` → `'=== NFC Archiver $version ($build) · $os · $locale · session start ==='`.
  - `Future<DiagnosticsFile?> startDiagnostics(Logger logger)` — resolves support dir, creates `DiagnosticsFile(dir: Directory('<support>/logs'))`, `addListener(file.add)`, writes `sessionHeader` (version/build from `PackageInfo.fromPlatform()`, os = `'${Platform.operatingSystem} ${Platform.operatingSystemVersion}'`, locale = `PlatformDispatcher.instance.locale.toLanguageTag()`), registers an `AppLifecycleListener(onPause: file.flush, onDetach: file.flush)`. Any failure → returns `null`, logger stays memory-only.
  - `main()`: after `ensureInitialized()`, `installErrorHooks(log)`; `final diagnostics = await startDiagnostics(log);`; add `diagnosticsFileProvider.overrideWithValue(diagnostics)`.

- [ ] **Step 1: Write failing tests:**
  - `FlutterError.onError logs and still presents the error` — save/restore `FlutterError.onError` and `FlutterError.presentError` in setUp/tearDown; replace `presentError` with a recorder; call `FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom'), stack: StackTrace.current))`; expect one `error` entry with detail containing `boom` and the recorder called once.
  - `PlatformDispatcher error hook reports and returns true`.
  - `a listener that throws inside the hook does not recurse` — add a listener that throws on every entry; invoke `FlutterError.onError` once; exactly one entry in `log.snapshot()`, no exception.
  - `sessionHeader format` — exact string for `('1.2.1','19','ios 18.5','en-US')`.
- [ ] **Step 2: Run** `flutter test test/diagnostics_hooks_test.dart` — FAIL.
- [ ] **Step 3: Implement** `diagnostics.dart` and wire `main.dart`.
- [ ] **Step 4: Run** the test file, then `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(log): persist the log from startup and capture uncaught errors`

### Task 4: iOS empty tag (`NFCError` 403) reads as empty

**Files:**
- Modify: `lib/features/nfc/domain/ndef_io.dart:67-84`
- Test: `test/ndef_io_test.dart`

**Interfaces:**
- Produces: `bool isEmptyNdefError(Object error)` (top-level, pure) — true iff `error is PlatformException && error.code.contains('Domain=NFCError Code=403')`. `Future<NdefMessage> readOrEmpty(Future<NdefMessage?> Function() read)` — awaits `read`, maps `null` via `ndefMessageOrEmpty`, and maps an `isEmptyNdefError` throw to the empty message; rethrows everything else. `IosNdefIO.read()` becomes `readOrEmpty(_ndef.readNdef)` (Android unchanged).

- [ ] **Step 1: Write failing tests** in `test/ndef_io_test.dart`, group `'iOS reports a blank tag as NFCError 403'`, using the exact strings from the maintainer's screenshot:
  ```dart
  final blank = PlatformException(
    code: 'Error Domain=NFCError Code=403 "NDEF tag does not contain any NDEF message" '
        'UserInfo={NSLocalizedDescription=NDEF tag does not contain any NDEF message}',
    message: 'NFCError',
    details: 'Stacktrace: ["0   Runner   0x0000000104807470 Runner + 111728"]',
  );
  ```
  - `isEmptyNdefError(blank)` is true; for `code: 'Error Domain=NFCError Code=102 "Tag response error"'` false; for `StateError('x')` false.
  - `readOrEmpty(() async => throw blank)` → `.records` empty.
  - `readOrEmpty(() async => throw PlatformException(code: '...Code=102...'))` → throws `PlatformException`.
- [ ] **Step 2: Run** `flutter test test/ndef_io_test.dart` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `fix(ios): a blank NDEF tag reads as empty, not as an error`

### Task 5: Typed `NfcFailure` through the reader layer, with localized text

**Files:**
- Create: `lib/features/nfc/domain/nfc_failure.dart`, `lib/features/nfc/presentation/nfc_failure_text.dart`
- Modify: `lib/l10n/app_en.arb` + `app_{ru,tr,uk,ka,pl,be}.arb`; the three screens' error consumers, minimally: `scan_screen.dart:124-125` → `scanError(nfcFailureText(next.failure, l10n))`, `write_progress_screen.dart:95-100` → same text into `writeError` and the existing SnackBar
- Modify: `lib/features/nfc/domain/card_reader.dart:79-113` (callbacks, `NfcReadError`/`NfcWriteError`), `lib/features/nfc/domain/ndef_availability.dart:48-58` (`messageFor` → `failureFor`), `lib/features/nfc/data/nfc_repository.dart` (read path ~:207-290, write path ~:300-480, `readTag`/`writeTag` ~:530-610), `lib/features/nfc/data/phone_nfc_reader.dart`, `lib/features/nfc/data/chameleon_reader.dart` (:126-145, :204-262, :285-302), `lib/features/nfc/presentation/providers/nfc_provider.dart` (`NfcSessionError`, :130-215), `test/support/fake_card_reader.dart`, every test using `onError`/`NfcSessionError(message:)` (`test/chameleon_reader_test.dart` and others found by `grep -rn "onError\|NfcSessionError" test`).
- Test: `test/nfc_failure_paths_test.dart`, `test/chameleon_reader_test.dart`, `test/ndef_availability_test.dart`, `test/nfc_failure_text_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum NfcFailureKind {
    noArchiveData,      // tag read fine but holds no NFAR chunk (blank or foreign content)
    readFailed,         // I/O / platform failure while reading
    writeFailed,
    tagNotWritable,
    notNdefFormatted,   // from NdefUnavailableReason.notNdefFormatted
    detectionFailed,    // from NdefUnavailableReason.detectionFailed
    mifareUnsupported,  // from NdefUnavailableReason.mifareUnsupported
    foreignCard,        // Chameleon CardAuthException
    nfcUnavailable,
    unknown,
  }
  class NfcFailure { const NfcFailure(this.kind); final NfcFailureKind kind; }
  NfcFailure failureFor(NdefUnavailableReason reason);   // replaces messageFor
  ```
  - `CardReader.startReadSession(... required void Function(NfcFailure failure) onError ...)`; same for `startWriteSession`.
  - `NfcSessionError({required NfcFailure failure})` (the `message` field is removed so every consumer fails to compile until mapped).
  - `NfcReadError({required NfcFailure failure})`, `NfcWriteError({required NfcFailure failure})`.
  - Rule at every throw site that becomes a failure: `log.report(<scope>, <short English message>, e, st)` **before** `onError(...)`. The failure carries no exception text.
  - iOS sheet text passed to `_ios.end(message: …)` is no longer the raw error: use `'No NFC Archiver data on this tag'` for `noArchiveData` and `"Couldn't read this tag"` / `"Couldn't write this tag"` otherwise (English; the sheet is a system surface and these strings already were English).
  - `String nfcFailureText(NfcFailure f, AppLocalizations l10n)`; `bool isNeutral(NfcFailure f)` → true only for `noArchiveData`.
- ARB keys (English copy fixed here; translate into all 6):
  | key | en |
  |---|---|
  | `nfcNoArchiveData` | `No NFC Archiver data on this tag` |
  | `nfcNoArchiveDataHint` | `Try another tag from this archive.` |
  | `nfcReadFailed` | `Couldn't read this tag` |
  | `nfcReadFailedHint` | `Hold it still against the phone and try again.` |
  | `nfcWriteFailed` | `Couldn't write this tag. Hold it still and try again.` |
  | `nfcTagNotWritable` | `This tag is read-only.` |
  | `nfcNotNdefFormatted` | `This tag doesn't support NDEF. Use a pre-formatted NDEF tag.` |
  | `nfcMifareUnsupported` | `This looks like a Mifare Classic card. Your phone's NFC chip can't read it.` |
  | `nfcForeignCard` | `This card is locked with keys the app doesn't have.` |
  | `somethingWentWrong` | `Something went wrong. Details are in the diagnostics log.` |
  | `details` | `Details` |
  `detectionFailed` and `readFailed` both map to `nfcReadFailed`; `nfcUnavailable` reuses the existing `nfcUnavailable` key; `unknown` → `somethingWentWrong`.
  - Chameleon: `bytes == null` → `log.info('reader', 'No NFAR chunk on card', {'uid': info.identifier})` and `onError(const NfcFailure(NfcFailureKind.noArchiveData))`. The poll loop's existing `_currentUid` check already fires `onTag` once per UID, so no extra de-duplication. `CardAuthException` → `foreignCard`; other exceptions → `log.report` + `readFailed`.

- [ ] **Step 1: Write failing tests:**
  - `test/ndef_availability_test.dart`: `failureFor` maps each `NdefUnavailableReason` to `detectionFailed` / `notNdefFormatted` / `mifareUnsupported`.
  - `test/chameleon_reader_test.dart`: `a card without an NFAR chunk reports noArchiveData once and logs it at info` — FakeChameleon with a blank Mifare card resting for 3 poll iterations; `errors` == `[NfcFailureKind.noArchiveData]`; one `info` entry `No NFAR chunk on card`. Update existing `onError: (m) => err = m` assertions to compare `failure.kind` (`foreignCard` for the CardAuthException case).
  - `test/nfc_failure_text_test.dart`: every `NfcFailureKind` maps to a non-empty string under `lookupAppLocalizations(const Locale('en'))`, and no mapped string contains `Exception` or `Stacktrace`; `isNeutral` true only for `noArchiveData`.
  - `test/nfc_failure_paths_test.dart`: `NfcSessionNotifier maps an unavailable reader to nfcUnavailable` (FakeCardReader with `isAvailable` false → state `NfcSessionError` with `failure.kind == nfcUnavailable`); `a thrown startReadSession is reported and becomes unknown` (fake throws `StateError('boom')` → `NfcSessionError(kind: unknown)` and a log entry whose detail contains `boom`).
- [ ] **Step 2: Run** those four files — FAIL (compile).
- [ ] **Step 3: Implement** across the listed files; update `FakeCardReader.lastOnError` type and all existing tests; `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter analyze` (no errors) and `flutter test` — PASS.
- [ ] **Step 5: Commit** `refactor(nfc): typed NfcFailure with translated text instead of raw error strings`

### Task 6: Scan screen notice cards, error budget, Details links

**Files:**
- Modify: `lib/features/restore/presentation/providers/restore_provider.dart` (`RestoreScanning`, `scanError` :184); `lib/features/restore/presentation/screens/scan_screen.dart` (listener :92-140, banner :349-370, catch :113-115); `lib/features/archive/presentation/screens/write_progress_screen.dart:92-101`
- Test: `test/scan_screen_notice_test.dart`, `test/write_progress_error_details_test.dart`

**Interfaces:**
- Consumes: `NfcFailure`, `NfcFailureKind`, `nfcFailureText`, `isNeutral`, ARB keys `nfcNoArchiveData*`, `nfcReadFailedHint`, `somethingWentWrong`, `details` (Task 5).
- Produces:
  - `RestoreScanning({..., String? lastError, bool lastErrorNeutral = false})`; `void scanError(String message, {bool neutral = false})`.
  - Route constant `const diagnosticsRoute = '/diagnostics';` in `lib/features/diagnostics/presentation/diagnostics_screen.dart` (create the file with just this constant and a placeholder `DiagnosticsScreen` returning `Scaffold()`; Task 9 fills it) and register the `GoRoute` in `lib/app.dart` now so Details buttons have a target.
- Scan screen behaviour:
  - `NfcSessionError` with `isNeutral` → `scanError(text, neutral: true)`, **no** `_consecutiveErrors++`; re-arm after `_retryFloor` (`Future.delayed(_retryFloor)` then `_startNfcSession()`, guarded by `mounted`).
  - Other failures → existing `_restartAfterError()` path, `scanError(text)`.
  - Banner: neutral → `surfaceContainerHighest` background, `Icons.info_outline`, title `nfcNoArchiveData`, body `nfcNoArchiveDataHint`; error → existing error styling, plus a `TextButton(details)` that does `context.push(diagnosticsRoute)`. For `readFailed`/`detectionFailed` show hint `nfcReadFailedHint` under the title.
  - `catch (e)` at :113 → `log.report('restore', 'processChunk failed', e, st)` + `scanError(l10n.somethingWentWrong)`.
- Write screen: `NfcSessionError` → `writeError(text)` and `SnackBar(content: Text(text), action: SnackBarAction(label: l10n.details, onPressed: () => context.push(diagnosticsRoute)))`.

- [ ] **Step 1: Write failing tests:**
  - `scan_screen_notice_test.dart` (follow `test/scan_screen_stop_test.dart` setup with `FakeCardReader`): fire `lastOnError!(NfcFailure(noArchiveData))` 6 times (pumping past `_retryFloor` each time) → text `No NFC Archiver data on this tag` shown, no `Details` button, scan not halted (`FakeCardReader.readArms` grew to 7, no `NfcSessionStopped`); fire `readFailed` → `Couldn't read this tag` and a `Details` button; tapping it navigates to `diagnosticsRoute`.
  - `write_progress_error_details_test.dart` (follow `test/write_progress_tag_type_mismatch_test.dart`): a write `onError(writeFailed)` shows a SnackBar with the `nfcWriteFailed` text and a `Details` action.
- [ ] **Step 2: Run** the two files — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter analyze` and `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(scan): readable, translated tag errors with a Details link`

### Task 7: Remaining raw-exception sites

**Files:**
- Modify: `lib/features/archive/presentation/providers/archive_provider.dart:272-274, :402`; `lib/features/archive/presentation/screens/write_progress_screen.dart:495+` (`_buildErrorView`); `lib/features/restore/presentation/providers/restore_provider.dart:277-282`; `lib/features/restore/data/restore_repository.dart:97`; `lib/features/restore/presentation/screens/restore_progress_screen.dart:498`; `lib/features/file_manager/presentation/providers/file_manager_provider.dart:57` + `file_manager_screen.dart:52`; `lib/features/archive/presentation/screens/file_picker_screen.dart:280-284`; `lib/features/nfc/presentation/providers/reader_provider.dart:93-98` + `reader_picker_screen.dart:130`
- Test: `test/raw_error_sites_test.dart`

**Interfaces:**
- Consumes: `Logger.report` (Task 1), `somethingWentWrong`, `details` (Task 5), `diagnosticsRoute` (Task 6).
- Rule: app-authored exceptions (`RestoreException`, `ArchiveException`, `CardAuthException`) keep their own `.message`. Any other caught object → `log.report(scope, '<what failed>', e, st)` and the state stores `message: null`; screens render `message ?? l10n.somethingWentWrong`. Make `ArchiveError.message`, `RestoreError.message`, `FileManagerError`'s message and `ReaderState.error`-as-shown nullable/flagged accordingly (for `ReaderState`, add `bool hasError` or keep `error` but set it to a fixed English marker never shown — builder's choice, as long as the screen shows the localized text).
- `restore_repository.dart:97`: `throw RestoreException('Failed to assemble chunks')` after `log.report('restore', 'assemble failed', e, st)`.
- `file_picker_screen.dart`: `errorSelectingFile(e.toString())` → `log.report('archive', 'file selection failed', e, st)` + `l10n.somethingWentWrong`. Leave the unused `errorSelectingFile` ARB key in place (removing keys across 7 files is churn).
- Each of these error views gets the same `Details` text button → `diagnosticsRoute`.

- [ ] **Step 1: Write failing tests** in `test/raw_error_sites_test.dart`:
  - `ArchiveNotifier: an unexpected exception during prepare stores no raw text and is logged` — drive the notifier with a repository/fake that throws `StateError('secret-detail')`; `ArchiveError.message` is null; `log.snapshot().last.detail` contains `secret-detail`.
  - `RestoreNotifier: same for an unexpected exception during restore`; `a RestoreException message is kept`.
  - `FileManagerNotifier: same for loadFiles`.
  (Use whichever seams exist; if a notifier has no injection point, add a constructor parameter defaulting to the current singleton.)
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** Then re-grep: `grep -rnE "e\.toString\(\)|'\\\$e'|: \\\$e|\\\$error" lib --include=*.dart` — every remaining hit is either a log call or not user-visible; note any you leave in the commit message.
- [ ] **Step 4: Run** `flutter analyze` and `flutter test` — PASS.
- [ ] **Step 5: Commit** `fix: no raw exception text on any screen`

### Task 8: Breadcrumbs

**Files:**
- Create: `lib/core/log/log_navigator_observer.dart`
- Modify: `lib/app.dart` (`GoRouter(observers: [LogNavigatorObserver()])`), `archive_provider.dart`, `restore_provider.dart`, `reader_provider.dart`
- Test: `test/breadcrumbs_test.dart`

**Interfaces:**
- Produces:
  - `class LogNavigatorObserver extends NavigatorObserver` — `didPush`/`didPop`/`didReplace` → `log.info('nav', 'open <name>')` / `'back to <name>'`, name = `route.settings.name ?? route.settings.toString()`; go_router sets `settings.name` to the matched location when routes are built via `GoRoute` (if it doesn't, use the page key/`GoRouterState.uri.path` via `pageBuilder` — builder's call).
  - In `ArchiveNotifier` and `RestoreNotifier`: `@override set state(T value) { log.info('<archive|restore>', 'state ${value.runtimeType}', breadcrumbData(value)); super.state = value; }` with a private `breadcrumbData` returning only: chunk index/total counts, sizes in bytes, tag type name, `compress`/`encrypt` booleans, archive ID. **No** file name, path, password, text content.
  - `reader_provider.dart`: `log.info('reader', 'switched', {'kind': kind.name, 'connected': isConnected})` on each state change.
- [ ] **Step 1: Write failing tests:**
  - `navigator observer logs pushes and pops` — pump a `MaterialApp` with the observer, push/pop a named route; two `nav` entries.
  - `archive breadcrumbs never contain the file name or password` — select a file named `tax-return-2026.pdf`, configure with encrypt + password `hunter2`, prepare (use existing archive test seams); `log.snapshot().map((e) => e.formatFull()).join()` does not contain `tax-return`, `.pdf` or `hunter2`, and contains `state ArchiveReady`.
  - `restore breadcrumbs carry chunk counts` — process a chunk; an entry `state RestoreScanning` with data containing the chunk index.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(log): breadcrumbs for navigation, archive, restore and reader`

### Task 9: Diagnostics log screen

**Files:**
- Modify: `lib/features/diagnostics/presentation/diagnostics_screen.dart` (placeholder from Task 6); `lib/shared/widgets/home_screen.dart:156-185` (About dialog button); ARB files
- Test: `test/diagnostics_screen_test.dart`

**Interfaces:**
- Consumes: `diagnosticsFileProvider` (Task 3), `DiagnosticsFile.readAll/clear/exportTo` (Task 2), `log.snapshot()`/`clear()`, `fileActionsProvider`/`FileActionsService.shareFile`, `sessionHeader`.
- Behaviour (layout A, accepted mockup):
  - Source: `diagnosticsFile?.readAll()` when the provider is non-null (shows previous sessions); otherwise the in-memory `log.snapshot()` filtered to `info`+ and rendered with `formatFull()`.
  - Lines in a monospace `SelectableText`/`ListView`, newest at the bottom, scrolled to the bottom on open. A line whose level column is `ERROR` and its indented detail lines use `colorScheme.error`; `WARN` uses `colorScheme.tertiary`.
  - `FilterChip`s: `diagnosticsFilterAll` / `diagnosticsFilterProblems` — the latter keeps `WARN`/`ERROR` lines plus their indented detail lines and session headers.
  - App bar: Share icon (`Icons.ios_share`) → `exportTo(await getTemporaryDirectory(), now: DateTime.now(), header: <sessionHeader of current run>)` then `shareFile(path)`; without a file sink, write the in-memory text to the temp file instead. Clear icon (`Icons.delete_outline`) → confirm dialog → `diagnosticsFile?.clear()` + `log.clear()` → reload.
  - Empty state: `diagnosticsEmpty`.
  - About dialog: a `TextButton(diagnosticsLog)` under "Privacy policy" that pops the dialog and pushes `diagnosticsRoute`.
- ARB keys: `diagnosticsLog` = `Diagnostics log`, `diagnosticsEmpty` = `Nothing logged yet.`, `diagnosticsFilterAll` = `All`, `diagnosticsFilterProblems` = `Warnings & errors`, `diagnosticsShare` = `Share log`, `diagnosticsClear` = `Clear log`, `diagnosticsClearConfirm` = `Delete the diagnostics log from this device?`, `diagnosticsClearAction` = `Clear`.

- [ ] **Step 1: Write failing tests** (override `diagnosticsFileProvider` with a `DiagnosticsFile` on a temp dir and `fileActionsProvider` with a `FileActionsService(sharer: recorder)`):
  - `shows persisted lines including an error's detail` — seed via `add()` of info + error-with-detail, flush; find text of both and of a detail line.
  - `Warnings & errors hides info lines but keeps the error's detail`.
  - `Share hands a nfc-archiver-log-*.txt to FileActionsService` — recorder got one `XFile` with `mimeType == 'text/plain'` and file content starting with `=== NFC Archiver`.
  - `Clear asks first, then empties the log` — cancel keeps lines; confirm shows `Nothing logged yet.`
  - `About dialog has a Diagnostics log entry that opens the screen` (pump `NfcArchiverApp`-style router or the home screen with a GoRouter).
- [ ] **Step 2: Run** `flutter test test/diagnostics_screen_test.dart` — FAIL.
- [ ] **Step 3: Implement**; `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter analyze` and `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat: diagnostics log screen with share and clear`

### Task 10: Privacy policy and project docs

**Files:**
- Modify: `site-docs/docs/{en,ru,tr,uk,ka,pl,be}/privacy.md` ("Diagnostic logs" section; en is lines 48-50 — locate the equivalent heading in each), `CLAUDE.md` (new short subsection under Architecture → Features), and if `test/privacy_policy_screen_test.dart` / the in-app privacy screen quote the log wording, update them too (`grep -rn "memory" lib/shared/widgets/privacy_policy_screen.dart lib/l10n/app_en.arb`).
- Test: `python3 site-docs/check_site.py` (see `site-docs/README.md` for the exact invocation)

- [ ] **Step 1: Replace the English section** with:
  > The app keeps a diagnostic log on your device: what it did and any errors it hit, so problems can be investigated. It is stored in a small file that is rotated automatically, and it never contains your files, file names or passwords. It is never sent anywhere. It leaves your device only if you share it yourself — from **About → Diagnostics log**, where you can also clear it at any time.
- [ ] **Step 2: Translate** that paragraph into the six other `privacy.md` files (same structure, same UI path in each language's in-app wording, i.e. the translated `diagnosticsLog` string).
- [ ] **Step 3: Run** the site check — PASS. Also check the in-app privacy text (if any) says the same.
- [ ] **Step 4: Add to `CLAUDE.md`** a `Diagnostics log` bullet: where the file lives, info+ only, never-log list, `log.report` rule for any caught exception shown to a user, `NfcFailure` instead of strings, and that the docs deploy must precede the app release carrying this feature.
- [ ] **Step 5: Run** `flutter analyze` and `flutter test` one final time — PASS.
- [ ] **Step 6: Commit** `docs: privacy policy and CLAUDE.md for the diagnostics log`

---

## Hardware verification (after merge, not CI)

- iPhone, phone radio: blank NTAG → "No NFC Archiver data on this tag", sheet ✕, scanning continues past 5 such taps; a URL sticker → same; Diagnostics log shows the entries; Share → Telegram accepts the `.txt`.
- Android (Pixel): same with a blank NTAG and a foreign Mifare card.
- Chameleon: blank Mifare card on the reader → neutral message once.
- Kill the app mid-scan, relaunch → previous session's lines still in the log.
