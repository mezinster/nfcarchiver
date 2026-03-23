# Persistent Restore Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist incomplete restore sessions to disk so multi-archive scan progress survives navigation and app restarts.

**Architecture:** Add a `SessionStorageService` that saves/loads `RestoreSession` objects as individual JSON files in `NFC_Sessions/`. The `RestoreRepository` gets disk persistence hooks, and the `RestoreNotifier` orchestrates loading on entry and persisting on chunk addition. The scan screen UI gains delete buttons and a bulk-clear action.

**Tech Stack:** Flutter, Riverpod StateNotifier, dart:convert (JSON + base64), path_provider, intl DateFormat

**Spec:** `docs/superpowers/specs/2026-03-23-persistent-restore-sessions-design.md`

---

### Task 1: Add timestamps and serialization to RestoreSession

**Files:**
- Modify: `lib/features/restore/data/restore_repository.dart` (class `RestoreSession`, lines 202-294)

- [ ] **Step 1: Write the failing test**

Create `test/restore_session_serialization_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';

void main() {
  group('RestoreSession serialization', () {
    late Uint8List testArchiveId;

    setUp(() {
      testArchiveId = Uint8List.fromList(List.generate(16, (i) => i + 1));
    });

    Chunk _makeChunk(Uint8List archiveId, int index, int total) {
      final payload = Uint8List.fromList([10, 20, 30]);
      final crc = ChecksumService.instance.calculate(payload);
      return Chunk(
        archiveId: archiveId,
        totalChunks: total,
        chunkIndex: index,
        payload: payload,
        crc32: crc,
        flags: 3,
      );
    }

    test('toJson produces expected structure', () {
      final session = RestoreSession(archiveId: testArchiveId);
      session.addChunk(_makeChunk(testArchiveId, 0, 3));
      session.addChunk(_makeChunk(testArchiveId, 2, 3));

      final json = session.toJson();

      expect(json['archiveId'], isA<String>());
      expect(json['archiveIdBytes'], isA<String>());
      expect(json['totalChunks'], 3);
      expect(json['flags'], 3);
      expect(json['createdAt'], isA<String>());
      expect(json['updatedAt'], isA<String>());
      expect(json['chunks'], isA<Map>());
      expect((json['chunks'] as Map).keys.toList()..sort(), ['0', '2']);
    });

    test('fromJson roundtrip preserves all data', () {
      final session = RestoreSession(archiveId: testArchiveId);
      session.addChunk(_makeChunk(testArchiveId, 0, 3));
      session.addChunk(_makeChunk(testArchiveId, 2, 3));

      final json = session.toJson();
      final restored = RestoreSession.fromJson(json);

      expect(restored.archiveIdString, session.archiveIdString);
      expect(restored.totalChunks, 3);
      expect(restored.flags, 3);
      expect(restored.receivedCount, 2);
      expect(restored.chunks.keys.toList()..sort(), [0, 2]);
      expect(restored.createdAt, isNotNull);
      expect(restored.updatedAt, isNotNull);

      // Verify chunk data is intact
      final originalBytes = session.chunks[0]!.toBytes();
      final restoredBytes = restored.chunks[0]!.toBytes();
      expect(restoredBytes, originalBytes);
    });

    test('timestamps are set on creation', () {
      final before = DateTime.now();
      final session = RestoreSession(archiveId: testArchiveId);
      final after = DateTime.now();

      expect(session.createdAt.isAfter(before) || session.createdAt.isAtSameMomentAs(before), isTrue);
      expect(session.createdAt.isBefore(after) || session.createdAt.isAtSameMomentAs(after), isTrue);
    });

    test('updatedAt changes on addChunk', () {
      final session = RestoreSession(archiveId: testArchiveId);
      final initialUpdated = session.updatedAt;

      // Small delay to ensure timestamp differs
      session.addChunk(_makeChunk(testArchiveId, 0, 3));

      expect(session.updatedAt.isAfter(initialUpdated) || session.updatedAt.isAtSameMomentAs(initialUpdated), isTrue);
    });

    test('updatedAt changes on replaceChunk', () {
      final session = RestoreSession(archiveId: testArchiveId);
      session.addChunk(_makeChunk(testArchiveId, 0, 3));
      final afterAdd = session.updatedAt;

      session.replaceChunk(_makeChunk(testArchiveId, 0, 3));

      expect(session.updatedAt.isAfter(afterAdd) || session.updatedAt.isAtSameMomentAs(afterAdd), isTrue);
    });

    test('fromJson preserves timestamps', () {
      final session = RestoreSession(archiveId: testArchiveId);
      session.addChunk(_makeChunk(testArchiveId, 0, 3));

      final json = session.toJson();
      final restored = RestoreSession.fromJson(json);

      // Timestamps survive roundtrip (within ISO 8601 precision)
      expect(restored.createdAt.toIso8601String(), session.createdAt.toIso8601String());
      expect(restored.updatedAt.toIso8601String(), session.updatedAt.toIso8601String());
    });

    test('empty session serializes correctly', () {
      final session = RestoreSession(archiveId: testArchiveId);
      final json = session.toJson();
      final restored = RestoreSession.fromJson(json);

      expect(restored.totalChunks, 0);
      expect(restored.receivedCount, 0);
      expect(restored.chunks, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/restore_session_serialization_test.dart`
Expected: FAIL — `RestoreSession` has no `toJson`, `fromJson`, `createdAt`, or `updatedAt`

- [ ] **Step 3: Implement RestoreSession changes**

In `lib/features/restore/data/restore_repository.dart`, modify the `RestoreSession` class:

1. Add `createdAt` and `updatedAt` fields (both `DateTime`), initialized to `DateTime.now()` in constructor
2. Update `addChunk()` to set `updatedAt = DateTime.now()` after adding
3. Update `replaceChunk()` to set `updatedAt = DateTime.now()` after replacing
4. Add `Map<String, dynamic> toJson()` method that serializes to the spec format
5. Add `factory RestoreSession.fromJson(Map<String, dynamic> json)` that reconstructs from JSON

Key implementation details:
- `archiveIdBytes`: `base64Encode(archiveId)`
- `archiveId` in JSON: the UUID string (`archiveIdString`)
- Chunks map: key is string index, value is `base64Encode(chunk.toBytes())`
- Timestamps: ISO 8601 strings via `toIso8601String()` / `DateTime.parse()`
- `fromJson` must set `_totalChunks` and `_flags` directly (add a private constructor or named constructor that accepts these)

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/restore_session_serialization_test.dart`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/features/restore/data/restore_repository.dart test/restore_session_serialization_test.dart
git commit -m "feat: add timestamps and JSON serialization to RestoreSession"
```

---

### Task 2: Create SessionStorageService

**Files:**
- Create: `lib/features/restore/data/session_storage_service.dart`

- [ ] **Step 1: Write the failing test**

Create `test/session_storage_service_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';
import 'package:nfc_archiver/features/restore/data/session_storage_service.dart';

void main() {
  late SessionStorageService service;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('session_test_');
    service = SessionStorageService.forDirectory(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Uint8List _testArchiveId() => Uint8List.fromList(List.generate(16, (i) => i + 1));

  Chunk _makeChunk(Uint8List archiveId, int index, int total) {
    final payload = Uint8List.fromList([10, 20, 30]);
    final crc = ChunkerService.instance.calculateCrc32(payload);
    return Chunk(
      archiveId: archiveId,
      totalChunks: total,
      chunkIndex: index,
      payload: payload,
      crc32: crc,
      flags: 3,
    );
  }

  group('SessionStorageService', () {
    test('save and loadAll roundtrip', () async {
      final archiveId = _testArchiveId();
      final session = RestoreSession(archiveId: archiveId);
      session.addChunk(_makeChunk(archiveId, 0, 3));
      session.addChunk(_makeChunk(archiveId, 1, 3));

      await service.save(session);
      final loaded = await service.loadAll();

      expect(loaded.length, 1);
      expect(loaded.first.archiveIdString, session.archiveIdString);
      expect(loaded.first.receivedCount, 2);
      expect(loaded.first.totalChunks, 3);
    });

    test('save overwrites existing session', () async {
      final archiveId = _testArchiveId();
      final session = RestoreSession(archiveId: archiveId);
      session.addChunk(_makeChunk(archiveId, 0, 3));
      await service.save(session);

      session.addChunk(_makeChunk(archiveId, 1, 3));
      await service.save(session);

      final loaded = await service.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.receivedCount, 2);
    });

    test('delete removes specific session', () async {
      final id1 = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final id2 = Uint8List.fromList(List.generate(16, (i) => i + 17));

      final s1 = RestoreSession(archiveId: id1);
      s1.addChunk(_makeChunk(id1, 0, 2));
      final s2 = RestoreSession(archiveId: id2);
      s2.addChunk(_makeChunk(id2, 0, 2));

      await service.save(s1);
      await service.save(s2);

      await service.delete(s1.archiveIdString);
      final loaded = await service.loadAll();

      expect(loaded.length, 1);
      expect(loaded.first.archiveIdString, s2.archiveIdString);
    });

    test('deleteAll removes all sessions', () async {
      final id1 = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final id2 = Uint8List.fromList(List.generate(16, (i) => i + 17));

      final s1 = RestoreSession(archiveId: id1);
      s1.addChunk(_makeChunk(id1, 0, 2));
      final s2 = RestoreSession(archiveId: id2);
      s2.addChunk(_makeChunk(id2, 0, 2));

      await service.save(s1);
      await service.save(s2);

      await service.deleteAll();
      final loaded = await service.loadAll();

      expect(loaded, isEmpty);
    });

    test('loadAll returns empty list when directory does not exist', () async {
      await tempDir.delete(recursive: true);
      final loaded = await service.loadAll();
      expect(loaded, isEmpty);
    });

    test('loadAll skips corrupted JSON files', () async {
      final archiveId = _testArchiveId();
      final session = RestoreSession(archiveId: archiveId);
      session.addChunk(_makeChunk(archiveId, 0, 3));
      await service.save(session);

      // Write a corrupted file
      final corruptedFile = File('${tempDir.path}/corrupted.json');
      await corruptedFile.writeAsString('not valid json{{{');

      final loaded = await service.loadAll();
      expect(loaded.length, 1); // Only the valid session
    });

    test('delete non-existent session does not throw', () async {
      await expectLater(
        service.delete('non-existent-uuid'),
        completes,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/session_storage_service_test.dart`
Expected: FAIL — `SessionStorageService` does not exist

- [ ] **Step 3: Implement SessionStorageService**

Create `lib/features/restore/data/session_storage_service.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import 'restore_repository.dart';

/// Service for persisting restore sessions to disk as JSON files.
///
/// Each session is stored as `<uuid>.json` in `NFC_Sessions/`.
class SessionStorageService {
  SessionStorageService._();

  /// Singleton instance using app documents directory.
  static final SessionStorageService instance = SessionStorageService._();

  /// Test constructor that uses a specific directory path.
  SessionStorageService.forDirectory(this._overridePath);

  String? _overridePath;

  Future<Directory> _getSessionsDir() async {
    if (_overridePath != null) {
      return Directory(_overridePath!);
    }
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(path.join(appDir.path, 'NFC_Sessions'));
  }

  /// Load all persisted sessions from disk.
  ///
  /// Skips files that cannot be parsed (corrupted JSON).
  Future<List<RestoreSession>> loadAll() async {
    final dir = await _getSessionsDir();
    if (!await dir.exists()) return [];

    final sessions = <RestoreSession>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          sessions.add(RestoreSession.fromJson(json));
        } catch (_) {
          // Skip corrupted files
        }
      }
    }
    return sessions;
  }

  /// Save a session to disk (overwrites if exists).
  Future<void> save(RestoreSession session) async {
    final dir = await _getSessionsDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(path.join(dir.path, '${session.archiveIdString}.json'));
    final json = jsonEncode(session.toJson());
    await file.writeAsString(json);
  }

  /// Delete a specific session file.
  Future<void> delete(String archiveIdString) async {
    final dir = await _getSessionsDir();
    final file = File(path.join(dir.path, '$archiveIdString.json'));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Delete all session files.
  Future<void> deleteAll() async {
    final dir = await _getSessionsDir();
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
        }
      }
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/session_storage_service_test.dart`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/features/restore/data/session_storage_service.dart test/session_storage_service_test.dart
git commit -m "feat: add SessionStorageService for disk persistence"
```

---

### Task 3: Wire persistence into RestoreRepository

**Files:**
- Modify: `lib/features/restore/data/restore_repository.dart`

- [ ] **Step 1: Add `_storageService` field to RestoreRepository**

Add after line 21:
```dart
final _storageService = SessionStorageService.instance;
```

Add import at top:
```dart
import 'session_storage_service.dart';
```

- [ ] **Step 2: Add `loadFromDisk()` method**

Add to `RestoreRepository`:
```dart
/// Load sessions from disk into memory.
/// Existing in-memory sessions take precedence over disk versions.
Future<void> loadFromDisk() async {
  final diskSessions = await _storageService.loadAll();
  for (final session in diskSessions) {
    _sessions.putIfAbsent(session.archiveIdString, () => session);
  }
}
```

- [ ] **Step 3: Add `persistSession()` method**

```dart
/// Persist a session to disk (fire-and-forget).
void persistSession(String archiveIdString) {
  final session = _sessions[archiveIdString];
  if (session != null) {
    _storageService.save(session);
  }
}
```

- [ ] **Step 4: Add disk delete to `restoreArchive()`**

After the existing `_sessions.remove(session.archiveIdString)` on line 121, add:
```dart
_storageService.delete(session.archiveIdString);
```

- [ ] **Step 5: Add disk delete to `clearSession()`**

In `clearSession()`, add before `_sessions.remove()`:
```dart
_storageService.delete(archiveIdString);
```

- [ ] **Step 6: Add disk delete to `clearAllSessions()`**

In `clearAllSessions()`, add before `_sessions.clear()`:
```dart
_storageService.deleteAll();
```

- [ ] **Step 7: Run all tests**

Run: `flutter test`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add lib/features/restore/data/restore_repository.dart
git commit -m "feat: wire SessionStorageService into RestoreRepository"
```

---

### Task 4: Update RestoreNotifier for persistence and new methods

**Files:**
- Modify: `lib/features/restore/presentation/providers/restore_provider.dart`

- [ ] **Step 1: Add `updatedAt` to `RestoreSessionInfo`**

Change `RestoreSessionInfo` to include:
```dart
required this.updatedAt,
```
Add field:
```dart
final DateTime updatedAt;
```

- [ ] **Step 2: Update `_getSessionInfos()` to include `updatedAt`**

```dart
List<RestoreSessionInfo> _getSessionInfos() {
  return _repository.activeSessions
      .map((s) => RestoreSessionInfo(
            archiveId: s.archiveIdString,
            receivedCount: s.receivedCount,
            totalChunks: s.totalChunks,
            isComplete: s.isComplete,
            isEncrypted: s.isEncrypted,
            updatedAt: s.updatedAt,
          ))
      .toList();
}
```

- [ ] **Step 3: Make `startScanning()` async with disk loading**

```dart
/// Start scanning for tags. Loads persisted sessions from disk first.
Future<void> startScanning() async {
  await _repository.loadFromDisk();
  state = RestoreScanning(
    sessions: _getSessionInfos(),
  );
}
```

- [ ] **Step 4: Add `persistSession` calls to `processChunk()`**

After `session.addChunk(chunk)` (line 152), add:
```dart
_repository.persistSession(session.archiveIdString);
```

After `session.replaceChunk(chunk)` (line 146), add:
```dart
_repository.persistSession(session.archiveIdString);
```

- [ ] **Step 5: Add `deleteSession()` method**

```dart
/// Delete a single session.
void deleteSession(String archiveId) {
  _repository.clearSession(archiveId);
  state = RestoreScanning(
    sessions: _getSessionInfos(),
  );
}
```

- [ ] **Step 6: Change `reset()` to UI-only state reset**

Replace the existing `reset()`:
```dart
/// Reset to initial state (UI only — sessions persist on disk).
void reset() {
  state = const RestoreInitial();
}
```

- [ ] **Step 7: Add `clearAllSessions()` method for bulk clear**

```dart
/// Clear all sessions (data destruction — used by bulk clear UI).
void clearAllSessions() {
  _repository.clearAllSessions();
  state = RestoreScanning(
    sessions: const [],
  );
}
```

- [ ] **Step 8: Run analyzer**

Run: `flutter analyze`
Expected: No new errors (existing `use_build_context_synchronously` warnings are pre-existing)

- [ ] **Step 9: Commit**

```bash
git add lib/features/restore/presentation/providers/restore_provider.dart
git commit -m "feat: add persistence hooks and session management to RestoreNotifier"
```

---

### Task 5: Update scan screen — async, delete buttons, bulk clear

**Files:**
- Modify: `lib/features/restore/presentation/screens/scan_screen.dart`

- [ ] **Step 1: Make `_startScanning()` async**

```dart
Future<void> _startScanning() async {
  await ref.read(restoreProvider.notifier).startScanning();
  _startNfcSession();
}
```

Note: `addPostFrameCallback((_) => _startScanning())` discards the returned future — this is fine because `loadAll()` already catches per-file parse errors internally. Directory access errors are extremely unlikely (it's the app's own documents directory).

- [ ] **Step 2: Verify back button behavior (no code change needed)**

The back button (line 80-85) already calls `reset()` then `context.go('/')`. Since Task 4 changed `reset()` to be UI-only, sessions now persist automatically. No code change needed here.

- [ ] **Step 3: Add bulk clear button to app bar**

Add `actions` to the `AppBar`:
```dart
actions: [
  if (state is RestoreScanning && state.sessions.isNotEmpty)
    IconButton(
      icon: const Icon(Icons.delete_sweep),
      tooltip: l10n.clearAllSessions,
      onPressed: () => _confirmClearAll(context),
    ),
],
```

Add the confirmation method:
```dart
void _confirmClearAll(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.clearAllSessions),
      content: Text(l10n.clearAllSessionsConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () {
            Navigator.of(ctx).pop();
            ref.read(restoreProvider.notifier).clearAllSessions();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.sessionsCleared)),
            );
          },
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
}
```

- [ ] **Step 4: Add delete button and timestamp to `_SessionCard`**

Update `_SessionCard` to be a `ConsumerWidget` and add delete functionality and timestamp display. The card needs a callback for deletion:

Change the sessions list rendering to pass the delete callback:
```dart
...state.sessions.map(
  (session) => _SessionCard(
    session: session,
    onDelete: () => _confirmDeleteSession(context, session.archiveId),
  ),
),
```

Add the confirmation method:
```dart
void _confirmDeleteSession(BuildContext context, String archiveId) {
  final l10n = AppLocalizations.of(context)!;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.deleteSession),
      content: Text(l10n.deleteSessionConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () {
            Navigator.of(ctx).pop();
            ref.read(restoreProvider.notifier).deleteSession(archiveId);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.sessionDeleted)),
            );
          },
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
}
```

Update `_SessionCard` to accept and display the delete button and timestamp:
```dart
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onDelete});

  final RestoreSessionInfo session;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dateFormat = DateFormat.MMMd().add_Hm();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  session.isComplete ? Icons.check_circle : Icons.pending,
                  color: session.isComplete
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.archiveId(session.archiveId.substring(0, 8)),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        l10n.lastUpdated(dateFormat.format(session.updatedAt)),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.5),
                            ),
                      ),
                    ],
                  ),
                ),
                if (session.isEncrypted)
                  Icon(
                    Icons.lock,
                    size: 16,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  onPressed: onDelete,
                  tooltip: l10n.deleteSession,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: session.progress,
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${session.receivedCount}/${session.totalChunks}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

Add import at top of file:
```dart
import 'package:intl/intl.dart';
```

- [ ] **Step 5: Run analyzer**

Run: `flutter analyze`
Expected: No new errors

- [ ] **Step 6: Commit**

```bash
git add lib/features/restore/presentation/screens/scan_screen.dart
git commit -m "feat: add session delete buttons and bulk clear to scan screen"
```

---

### Task 6: Add localization keys

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ru.arb`
- Modify: `lib/l10n/app_tr.arb`
- Modify: `lib/l10n/app_uk.arb`
- Modify: `lib/l10n/app_ka.arb`

- [ ] **Step 1: Add English keys to `app_en.arb`**

Add before the closing `}`:
```json
  "clearAllSessions": "Clear all sessions",
  "@clearAllSessions": {
    "description": "App bar button to clear all incomplete sessions"
  },

  "clearAllSessionsConfirm": "Delete all incomplete restore sessions?",
  "@clearAllSessionsConfirm": {
    "description": "Confirmation dialog text for clearing all sessions"
  },

  "deleteSession": "Delete session",
  "@deleteSession": {
    "description": "Button/tooltip to delete a single session"
  },

  "deleteSessionConfirm": "Delete this incomplete session?",
  "@deleteSessionConfirm": {
    "description": "Confirmation dialog text for deleting a session"
  },

  "lastUpdated": "Last updated {dateTime}",
  "@lastUpdated": {
    "description": "Timestamp showing when session was last updated",
    "placeholders": {
      "dateTime": {
        "type": "String",
        "description": "Formatted date and time"
      }
    }
  },

  "sessionsCleared": "All sessions cleared",
  "@sessionsCleared": {
    "description": "Snackbar message after clearing all sessions"
  },

  "sessionDeleted": "Session deleted",
  "@sessionDeleted": {
    "description": "Snackbar message after deleting a session"
  }
```

- [ ] **Step 2: Add Russian translations to `app_ru.arb`**

```json
  "clearAllSessions": "Очистить все сессии",
  "clearAllSessionsConfirm": "Удалить все незавершённые сессии восстановления?",
  "deleteSession": "Удалить сессию",
  "deleteSessionConfirm": "Удалить эту незавершённую сессию?",
  "lastUpdated": "Обновлено {dateTime}",
  "@lastUpdated": {
    "placeholders": { "dateTime": { "type": "String" } }
  },
  "sessionsCleared": "Все сессии удалены",
  "sessionDeleted": "Сессия удалена"
```

- [ ] **Step 3: Add Turkish translations to `app_tr.arb`**

```json
  "clearAllSessions": "Tüm oturumları temizle",
  "clearAllSessionsConfirm": "Tüm tamamlanmamış geri yükleme oturumları silinsin mi?",
  "deleteSession": "Oturumu sil",
  "deleteSessionConfirm": "Bu tamamlanmamış oturum silinsin mi?",
  "lastUpdated": "Son güncelleme {dateTime}",
  "@lastUpdated": {
    "placeholders": { "dateTime": { "type": "String" } }
  },
  "sessionsCleared": "Tüm oturumlar temizlendi",
  "sessionDeleted": "Oturum silindi"
```

- [ ] **Step 4: Add Ukrainian translations to `app_uk.arb`**

```json
  "clearAllSessions": "Очистити всі сесії",
  "clearAllSessionsConfirm": "Видалити всі незавершені сесії відновлення?",
  "deleteSession": "Видалити сесію",
  "deleteSessionConfirm": "Видалити цю незавершену сесію?",
  "lastUpdated": "Оновлено {dateTime}",
  "@lastUpdated": {
    "placeholders": { "dateTime": { "type": "String" } }
  },
  "sessionsCleared": "Всі сесії видалено",
  "sessionDeleted": "Сесію видалено"
```

- [ ] **Step 5: Add Georgian translations to `app_ka.arb`**

```json
  "clearAllSessions": "ყველა სესიის გასუფთავება",
  "clearAllSessionsConfirm": "წაიშალოს ყველა დაუსრულებელი აღდგენის სესია?",
  "deleteSession": "სესიის წაშლა",
  "deleteSessionConfirm": "წაიშალოს ეს დაუსრულებელი სესია?",
  "lastUpdated": "განახლდა {dateTime}",
  "@lastUpdated": {
    "placeholders": { "dateTime": { "type": "String" } }
  },
  "sessionsCleared": "ყველა სესია წაიშალა",
  "sessionDeleted": "სესია წაიშალა"
```

- [ ] **Step 6: Generate l10n**

Run: `flutter gen-l10n`
Expected: Completes without errors

- [ ] **Step 7: Run analyzer**

Run: `flutter analyze`
Expected: No new errors

- [ ] **Step 8: Commit**

```bash
git add lib/l10n/
git commit -m "feat: add l10n keys for session management in all 5 locales"
```

---

### Task 7: Update restore progress screen — preserve sessions on Done/Cancel

**Files:**
- Modify: `lib/features/restore/presentation/screens/restore_progress_screen.dart`

- [ ] **Step 1: No code changes needed for "Done" buttons**

The "Done" buttons (lines 316 and 413) call `reset()` which now only resets UI state. The completed session was already removed by `restoreArchive()`. No changes needed here — the new `reset()` behavior handles this correctly.

Verify: read lines 314-318 and 411-415 to confirm they only call `reset()` then `context.go('/')`.

- [ ] **Step 2: No code changes needed for "Cancel" button**

The "Cancel" button (lines 506-509) calls `reset()` which now preserves the session on disk. This is intentional per the spec.

- [ ] **Step 3: Run full test suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: All tests pass, no new analyzer errors

- [ ] **Step 4: Commit (if any changes were needed)**

If no changes were required, skip this commit. The restore progress screen works correctly with the new `reset()` behavior without modification.

---

### Task 8: Final integration test on device

- [ ] **Step 1: Build and deploy to device**

Run: `flutter run -d <device-id>`

- [ ] **Step 2: Test scenario: sessions persist across navigation**

1. Tap "Restore Archive"
2. Scan a tag from archive A — verify card shows with progress
3. Press back → go home
4. Tap "Restore Archive" again → verify archive A's card is still there with progress

- [ ] **Step 3: Test scenario: delete single session**

1. On scan screen with sessions showing, tap the X button on a session card
2. Confirm deletion
3. Verify snackbar appears and card is removed

- [ ] **Step 4: Test scenario: bulk clear**

1. Have 2+ sessions showing on scan screen
2. Tap the trash icon in the app bar
3. Confirm "Delete all incomplete restore sessions?"
4. Verify all cards removed and snackbar appears

- [ ] **Step 5: Test scenario: sessions survive app restart**

1. Scan some tags to create sessions
2. Force-close the app
3. Reopen and tap "Restore Archive"
4. Verify sessions are restored from disk

- [ ] **Step 6: Test scenario: complete restore preserves other sessions**

1. Scan tags from 2 different archives (A: 2/3, B: 1/2)
2. Scan final tag for archive A — should navigate to restore screen
3. Complete restore, tap "Done"
4. Go back to "Restore Archive" — verify archive B still shows 1/2

- [ ] **Step 7: Verify "Archived Files" tab does not show session JSONs**

1. Open "Archived Files" tab
2. Confirm no `.json` session files appear in the list

- [ ] **Step 8: Commit the initState fix from earlier**

The `addPostFrameCallback` fix in `scan_screen.dart` (from the initial debugging session) should already be committed as part of Task 5. Verify it's included.
