# Card Inspector UI — Implementation Plan (sub-project C, second half)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the inspector core behind a Flutter dialog reachable when a Chameleon is connected — live identity, NFAR description and hex rows as the dump progresses, with Copy and Share.

**Architecture:** `runInspection` orchestrates the core pieces and reports through a six-method `InspectSink`, exactly as the web app's `InspectIO` does, so it is testable with no widgets. `InspectNotifier` implements `InspectSink`, owns a `CancellationToken`, and exposes Riverpod state to the dialog.

**Tech Stack:** Flutter, Riverpod, `share_plus`, `mime`, `flutter_test`. **No new dependency.**

**Spec:** `docs/superpowers/specs/2026-07-31-flutter-card-inspector-design.md`

## Prerequisite

**Tasks 1–6 of `docs/superpowers/plans/2026-07-31-flutter-chameleon-ble.md` must be complete** — this plan consumes `ChameleonDevice`, `FakeChameleonDevice`, `CancellationToken`, `dumpCard`, `describeNfar`, `nfarBytesSoFar`, the `hex_view` formatters and `diagnoseCard`. Tasks 7–12 of that plan (BLE and reader selection) are needed only for Task 5 here, which wires the real entry point.

## Global Constraints

1. **Read-only.** Nothing in this plan may write to a card. Sector trailers are displayed, never modified.
2. **The report body stays English.** Only the dialog's chrome is localised. This is a deliberate decision recorded in `CLAUDE.md` — the report is diagnostic output meant to be pasted into a bug report, and a translated hex dump helps nobody. Do not "fix" it.
3. **New chrome strings go in `lib/l10n/app_en.arb` and all six translations**, then `flutter gen-l10n`.
4. **A superseded inspection may only touch state it still owns.** Ownership is checked inside **every** `InspectSink` method, never only at entry.
5. **`Share.shareXFiles` must carry an explicit MIME type** from `lookupMimeType()`, per `CLAUDE.md` — without it Android reports `application/octet-stream` and strict apps refuse to send.
6. Verify with `flutter analyze` and `flutter test`; run `flutter gen-l10n` first when ARB files changed.
7. Baseline: all existing tests pass. No task may reduce that.

## Shared test helpers

Extend `test/support/helpers.dart` (created by Task 1 of the BLE plan) rather than redefining these per file:

```dart
/// An InspectSink that forwards to [inner] and fires hooks, for asserting on
/// ORDERING — e.g. that identity arrives before the first row.
InspectSink spy(InspectSink inner, {void Function()? onFirstRow, void Function(int)? onRow});

/// Pumps a ProviderScope hosting the inspector dialog against [device].
Widget host(ChameleonDevice device);

/// Captures Clipboard.setData calls via the platform channel mock.
void mockClipboard(List<MethodCall> out);

/// A FakeChameleonDevice with a per-block delay, so cancellation and
/// supersede tests have a run long enough to interrupt.
ChameleonDevice slowDevice({Duration perBlock = const Duration(milliseconds: 5)});
```

`FakeChameleonDevice` also gains, for this plan: `failAnticollision()`, `delayPerBlock(Duration)`, and `writeNfar(Uint8List)` (which stores the chunk **in the medium's native envelope** — raw blocks on Classic, a Type-2 TLV wrapping an NDEF record on NTAG).

---

### Task 1: `InspectSink` and `runInspection`

**Files:**
- Create: `lib/features/inspect/domain/inspect_sink.dart`
- Create: `lib/features/inspect/domain/run_inspection.dart`
- Test: `test/run_inspection_test.dart`

**Interfaces:**
- Consumes: `dumpCard`, `describeNfar`, `nfarBytesSoFar`, `diagnoseCard`, the `hex_view` formatters, `CancellationToken`
- Produces: `InspectSink`, `runInspection(ChameleonDevice dev, InspectSink sink, {CancellationToken? token})`

Port of `webapp/app/ui/inspect-orchestrator.ts:100-159`.

- [ ] **Step 1: Write the sink**

```dart
// lib/features/inspect/domain/inspect_sink.dart
/// How runInspection reports progress. Six methods, mirroring the web app's
/// InspectIO, so the orchestration is testable without any widget.
abstract class InspectSink {
  void setIdentity(String text);
  void setNfar(String text);
  void appendRow(String line);
  void setProgress(String text);
  void setReport(String text);
  void setStatus(String text);
}
```

Callbacks rather than a `Stream<InspectEvent>`: a stream would diverge both from the TypeScript this is ported from and from this app's own convention, where every NFC session is already driven through `onTagDiscovered` / `onChunkRead` / `onError`. The idiomatic Riverpod surface is added one layer up in Task 2.

- [ ] **Step 2: Write the failing tests**

```dart
// test/run_inspection_test.dart
class RecordingSink implements InspectSink {
  final rows = <String>[];
  String? identity, nfar, progress, report, status;
  @override void appendRow(String l) => rows.add(l);
  @override void setIdentity(String t) => identity = t;
  @override void setNfar(String t) => nfar = t;
  @override void setProgress(String t) => progress = t;
  @override void setReport(String t) => report = t;
  @override void setStatus(String t) => status = t;
}

void main() {
  test('identity is reported before any block is read', () async {
    final sink = RecordingSink();
    var identityAtFirstRow;
    await runInspection(FakeChameleonDevice.classic1k(), _spy(sink,
        onFirstRow: () => identityAtFirstRow = sink.identity));
    expect(identityAtFirstRow, isNotNull,
        reason: 'onMeta must fire before the first read, or the user stares '
               'at an empty dialog for ~64 BLE round trips');
  });

  test('a full Classic inspection emits one row per block and a report', () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k(), sink);
    expect(sink.rows.length, 64);
    expect(sink.report, isNotNull);
    expect(sink.nfar, isNotNull);
  });

  test('a failed anticollision does NOT stop the dump', () async {
    // diagnoseCard is advisory: readBlock performs its own select.
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k()..failAnticollision(), sink);
    expect(sink.rows.length, 64);
  });

  test('an unsupported tag keeps its specific message instead of a generic one', () async {
    // For an inspector the SAK value in that message IS the result.
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k()..overrideSak(0x20), sink);
    expect(sink.status, contains('0x20'));
  });

  test('cancellation reports stopped, not done', () async {
    final sink = RecordingSink();
    final token = CancellationToken();
    await runInspection(FakeChameleonDevice.classic1k(),
        _spy(sink, onRow: (n) { if (n == 5) token.cancel(); }), token: token);
    expect(sink.status, isNot(contains('complete')));
    expect(sink.report, isNotNull, reason: 'a partial dump is still a usable artefact');
  });

  test('an NTAG card is described from the unwrapped TLV, not raw pages', () async {
    // Concatenated raw pages start with the TLV header, so without the
    // unwrap every NTAG card would be reported "not NFAR".
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.ntag215()..writeNfar(validChunkBytes()), sink);
    expect(sink.nfar, contains('NFAR'));
  });
}
```

- [ ] **Step 3: Run to verify failure**

`flutter test test/run_inspection_test.dart` → FAIL, file not found.

- [ ] **Step 4: Implement `runInspection`**

Flow, ported from the TypeScript:

1. `sink.setStatus(...)` — hold the card still.
2. `diagnoseCard` inside a try/catch. **A failure here must not stop the dump** — the anticollision is advisory, because `readBlock` performs its own select. On failure `diag` is null and the identity block simply omits it.
3. `dumpCard` with:
   - `onMeta` → `sink.setIdentity(formatIdentity(meta, diag))`, so identity appears in about a second rather than after ~64 BLE round trips.
   - `onUnit` → record the unit, `sink.appendRow(formatUnitRow(unit))`, `sink.setProgress(...)`, and **re-describe the NFAR header only while it is still incomplete** (`nfar is NfarAbsent || nfar.crcValid == null`). Pass `capacityBytes: cardCapacityBytes` for Classic only; on NTAG the TLV length already bounds it, so no capacity is guessed.
4. On completion: `setNfar`, `setReport(formatReport(result.meta, diag, nfar, result.units))`, and a status of stopped / card-lost / done.
5. On `UnsupportedTagException`, surface **`e.message` verbatim**. A generic "unsupported tag" string would discard the SAK value, which for an inspector is the entire result.

- [ ] **Step 5: Run to verify pass**

- [ ] **Step 6: Commit**

```bash
git add lib/features/inspect/domain test/run_inspection_test.dart
git commit -m "feat(inspect): inspection orchestration behind a testable sink"
```

---

### Task 2: `InspectNotifier` and the ownership guard

**Files:**
- Create: `lib/features/inspect/presentation/providers/inspect_provider.dart`
- Test: `test/inspect_notifier_test.dart`

**Interfaces:**
- Consumes: `InspectSink`, `runInspection`, `CancellationToken`
- Produces: `InspectState`, `InspectNotifier`, `inspectProvider`

- [ ] **Step 1: Write the failing tests**

The second test is the regression test for the web app's commit `67c4683` and is the reason this task exists as its own gate.

```dart
test('state accumulates rows, identity, nfar and report', () async {
  final n = InspectNotifier();
  await n.start(FakeChameleonDevice.classic1k());
  expect(n.state.rows.length, 64);
  expect(n.state.report, isNotNull);
  expect(n.state.isRunning, isFalse);
});

test('a superseded run cannot write into the run that replaced it', () async {
  // NOT merely "cancel sets a flag": the failure mode is run 1's in-flight
  // callbacks scribbling rows and progress into run 2's state.
  final n = InspectNotifier();
  final slow = FakeChameleonDevice.classic1k()..delayPerBlock(const Duration(milliseconds: 5));
  final first = n.start(slow);              // deliberately not awaited
  await pump();
  await n.start(FakeChameleonDevice.classic1k());  // supersedes it
  final rowsAfterSecond = n.state.rows.length;
  await first;                              // let the stale run drain
  expect(n.state.rows.length, rowsAfterSecond,
      reason: 'late callbacks from the superseded run must be dropped');
});

test('cancel() stops the run and leaves the partial result visible', () async {
  final n = InspectNotifier();
  final slow = FakeChameleonDevice.classic1k()..delayPerBlock(const Duration(milliseconds: 5));
  final f = n.start(slow);
  await pump();
  n.cancel();
  await f;
  expect(n.state.isRunning, isFalse);
  expect(n.state.rows, isNotEmpty);
});

test('starting a new run clears the previous run\'s rows', () async {
  final n = InspectNotifier();
  await n.start(FakeChameleonDevice.classic1k());
  await n.start(FakeChameleonDevice.ntag215());
  expect(n.state.rows.length, lessThan(64), reason: 'NTAG has fewer units');
});
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement**

`InspectState` is immutable: `rows` (`List<String>`), `identity`, `nfar`, `progress`, `report`, `status`, `isRunning`.

`InspectNotifier extends StateNotifier<InspectState> implements InspectSink`. It holds `CancellationToken? _token`. `start()` cancels any previous token, creates a new one, stores it, resets state, then calls `runInspection`.

**Every `InspectSink` method begins with the same ownership check:**

```dart
// A guard only at entry does not help: the damage is done by callbacks
// already scheduled when the second run started. Same rule as readerEpoch in
// device.ts, browser-ndef-io.ts's cleanup, and ReaderLock.release.
bool _owns(CancellationToken t) => identical(t, _token) && !t.isCancelled;
```

The token each callback checks is the one captured when *that* run started — closed over, not read from the field — so a stale run compares its own token against the current one and finds it superseded.

- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** — `git commit -m "feat(inspect): Riverpod notifier with superseded-run ownership guard"`

---

### Task 3: Localisation

**Files:**
- Modify: `lib/l10n/app_en.arb` and `app_ru`, `app_tr`, `app_uk`, `app_ka`, `app_pl`, `app_be`

- [ ] **Step 1: Add the chrome strings to `app_en.arb`**

| Key | English |
|---|---|
| `inspectTitle` | Inspect card |
| `inspectIdentity` | Identity |
| `inspectNfar` | NFAR chunk |
| `inspectRaw` | Raw |
| `inspectHoldStill` | Hold the card still on the reader… |
| `inspectReading` | Reading {done} of {total}… |
| `inspectRead` | Read {done} of {total} |
| `inspectDone` | Inspection complete. |
| `inspectStopped` | Stopped. |
| `inspectCardLost` | Card left the field — partial dump. |
| `inspectCopy` | Copy |
| `inspectCopied` | Report copied. |
| `inspectShare` | Share |
| `inspectClose` | Close |
| `inspectNeedsChameleon` | Card inspection needs a Chameleon — phone NFC has no raw card access. |

`inspectReading` and `inspectRead` take `{done}` and `{total}` placeholders and need `placeholders` entries with `type: "int"` in the ARB.

- [ ] **Step 2: Translate into all six other catalogues**

- [ ] **Step 3: Regenerate and verify**

```bash
flutter gen-l10n && flutter analyze && flutter test
```

- [ ] **Step 4: Commit** — `git commit -m "i18n: card inspector chrome in all seven locales"`

---

### Task 4: The inspector dialog

**Files:**
- Create: `lib/features/inspect/presentation/screens/inspect_dialog.dart`
- Test: `test/inspect_dialog_test.dart`

**Interfaces:**
- Consumes: `inspectProvider`, the l10n strings from Task 3

- [ ] **Step 1: Write the failing widget tests**

```dart
testWidgets('rows appear progressively rather than only at the end', (t) async {
  await t.pumpWidget(_host(slowDevice));
  await t.pump(const Duration(milliseconds: 20));
  expect(find.byType(SelectableText), findsWidgets,
      reason: 'a 64-block dump must not look frozen while it runs');
});

testWidgets('Copy puts the report on the clipboard', (t) async {
  final calls = <MethodCall>[];
  _mockClipboard(calls);
  await t.pumpWidget(_host(FakeChameleonDevice.classic1k()));
  await t.pumpAndSettle();
  await t.tap(find.text('Copy'));
  expect(calls.single.method, 'Clipboard.setData');
});

testWidgets('closing the dialog cancels the run', (t) async {
  await t.pumpWidget(_host(slowDevice));
  await t.pump(const Duration(milliseconds: 10));
  await t.tap(find.text('Close'));
  await t.pumpAndSettle();
  expect(container.read(inspectProvider).isRunning, isFalse,
      reason: 'a dialog dismissed mid-dump must not leave a run polling the reader');
});

testWidgets('an unsupported tag shows its specific message', (t) async {
  await t.pumpWidget(_host(FakeChameleonDevice.classic1k()..overrideSak(0x20)));
  await t.pumpAndSettle();
  expect(find.textContaining('0x20'), findsOneWidget);
});
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement the dialog**

A full-screen dialog with three sections — Identity, NFAR chunk, Raw — plus a progress line and Copy / Share / Close.

- The Raw section is a scrolling monospace list of `state.rows`, built lazily (`ListView.builder`): 64 rows is fine, but the widget must not assume a small list.
- Use `SelectableText` with a monospace style so a user can grab part of a dump without using Copy.
- **`Close` calls `notifier.cancel()`** before popping. A dialog dismissed mid-dump must not leave a run polling the reader.
- Also cancel on back-button dismissal — wrap in `PopScope` so the hardware back button takes the same path as the Close button.

- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** — `git commit -m "feat(inspect): card inspector dialog"`

---

### Task 5: Share, and the entry point

**Files:**
- Create: `lib/features/inspect/data/report_share.dart`
- Modify: `lib/shared/widgets/home_screen.dart` (or wherever Task 12 of the BLE plan put the reader status) — add the Inspect action
- Test: `test/report_share_test.dart`

**Interfaces:**
- Consumes: `share_plus`, `mime`, `path_provider`, the active `CardReader`

- [ ] **Step 1: Write the failing test**

```dart
test('the shared report file is typed text/plain, never octet-stream', () async {
  // CLAUDE.md: without an explicit MIME type Android's ContentResolver
  // reports application/octet-stream and strict apps (Telegram) refuse to
  // send. Same class of bug as the untyped Blob in the web app.
  final f = await writeReportFile('report text', dir: tempDir);
  expect(lookupMimeType(f.path), 'text/plain');
});

test('the filename carries the card UID so two dumps do not collide', () async {
  final f = await writeReportFile('x', dir: tempDir, uid: 'DEADBEEF');
  expect(f.path, contains('DEADBEEF'));
});
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement `report_share.dart`**

Write the report to a `.txt` in the temp directory, named with the card UID, and share via `Share.shareXFiles` with `mimeType: lookupMimeType(path)`.

- [ ] **Step 4: Wire the entry point**

An **Inspect card** action beside the reader status. Enabled only when the active `CardReader` reports `supportsRawAccess == true`.

**Visible-but-disabled under phone NFC, never hidden**, with `inspectNeedsChameleon` as its tooltip — a silently absent control teaches the user nothing, and this matches the web app's treatment exactly.

- [ ] **Step 5: Run `flutter analyze && flutter test`**
- [ ] **Step 6: Commit** — `git commit -m "feat(inspect): share the report with an explicit MIME type; wire the entry point"`

---

## Verification summary

| Gate | Command | Expected |
|---|---|---|
| Static analysis | `flutter analyze` | clean |
| All tests | `flutter test` | all pass, baseline never reduced |
| Locales complete | `flutter gen-l10n` | no missing-translation warnings |
| Superseded runs | `test/inspect_notifier_test.dart` | late callbacks dropped |
| Share typing | `test/report_share_test.dart` | `text/plain`, not octet-stream |

## Hardware validation (cannot be automated)

1. A real card's identity block renders correctly, including a 7-byte cascade UID.
2. A foreign card's sectors surface as `authFailed` rows rather than aborting the dump.
3. A 64-block Classic dump over BLE completes in a tolerable time — **currently unknown and deliberately not guessed at**; if it is slow enough to feel broken, the progress line is the mitigation already in place.
4. Removing the card mid-dump produces a partial report marked card-lost, not a hang.
5. Share hands a `text/plain` file to a strict receiver (Telegram is the known-strict case).

## Non-goals

- Writing, formatting, or key recovery — an unreadable sector is reported and the dump continues
- Inspection over phone NFC — `nfc_manager` exposes no raw anticollision or arbitrary block access
- Translating the report body (Global Constraint 2)
- A binary `.mfd`/`.bin` export for other tooling — plausible later, out of scope here
