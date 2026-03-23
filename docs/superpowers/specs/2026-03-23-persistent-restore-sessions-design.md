# Persistent Restore Sessions

**Date:** 2026-03-23
**Status:** Approved

## Problem

When scanning NFC tags from multiple archives, completing one archive's restore navigates the user home and wipes all in-memory sessions. Progress on incomplete archives is lost. Users must rescan all tags for those archives from scratch.

## Solution

Persist incomplete restore sessions to disk as individual JSON files. Sessions survive app restarts and navigation. Users can view, resume, and delete sessions from the scan screen.

## Storage Layer

### Location

`<app_documents>/NFC_Sessions/<uuid>.json`

This directory is a sibling of `NFC_Archives/` (where restored files are saved). The file manager's "Archived files" tab only scans `NFC_Archives/` non-recursively, so session files are invisible to it.

### File Format

Each session is a standalone JSON file named by its archive UUID:

```json
{
  "archiveId": "550e8400-e29b-41d4-a716-446655440000",
  "archiveIdBytes": "<base64-encoded 16-byte UUID>",
  "totalChunks": 7,
  "flags": 3,
  "createdAt": "2026-03-23T19:52:00Z",
  "updatedAt": "2026-03-23T19:55:00Z",
  "chunks": {
    "0": "<base64-encoded chunk bytes via Chunk.toBytes()>",
    "2": "<base64-encoded chunk bytes via Chunk.toBytes()>"
  }
}
```

Chunks are serialized using the existing `Chunk.toBytes()` method and base64-encoded. Deserialization uses `Chunk.fromBytes()`. Timestamps track session freshness for the UI.

### New Class: `SessionStorageService`

**File:** `lib/features/restore/data/session_storage_service.dart`

Singleton, same pattern as other services (`SessionStorageService.instance`). Instantiated as a field in `RestoreRepository`:

```dart
final _storageService = SessionStorageService.instance;
```

Responsibilities:
- `Future<List<RestoreSession>> loadAll()` — read all session JSON files, reconstruct `RestoreSession` objects via `RestoreSession.fromJson()`
- `Future<void> save(RestoreSession session)` — write/overwrite a session's JSON file using `RestoreSession.toJson()`
- `Future<void> delete(String archiveIdString)` — delete a single session file
- `Future<void> deleteAll()` — delete all session files (clear directory)

### RestoreSession Serialization

`RestoreSession` gains two new methods and a factory constructor:

- **`RestoreSession.fromJson(Map<String, dynamic> json)`** — factory constructor that creates a fully populated session. Sets `archiveId` from base64-decoded `archiveIdBytes`, `_totalChunks` from `totalChunks`, `_flags` from `flags`, `createdAt` and `updatedAt` from ISO 8601 strings, and populates `_chunks` by iterating the `chunks` map and calling `Chunk.fromBytes()` on each base64-decoded value.
- **`Map<String, dynamic> toJson()`** — serializes the session to the JSON format above. Base64-encodes `archiveId` bytes and each chunk's `toBytes()` output.

`RestoreSession` also gains two new fields:

- **`DateTime createdAt`** — set to `DateTime.now()` in the default constructor, preserved from JSON in `fromJson()`.
- **`DateTime updatedAt`** — set to `DateTime.now()` in the default constructor, updated in `addChunk()` and `replaceChunk()`.

### RestoreSessionInfo Timestamp

`RestoreSessionInfo` gains a `DateTime updatedAt` field. `_getSessionInfos()` in `RestoreNotifier` populates it from `RestoreSession.updatedAt`.

## Repository Changes

**`RestoreRepository`** changes:

1. **Loading:** New `Future<void> loadFromDisk()` method calls `SessionStorageService.loadAll()` and populates the in-memory `_sessions` map. Called when entering the scan screen. Existing in-memory sessions (from current scanning) take precedence over disk versions.

2. **New `persistSession(String archiveIdString)`:** Looks up the session in `_sessions` and calls `_storageService.save()` fire-and-forget (unawaited). Disk write failures are silently ignored — the in-memory session is the source of truth during runtime. Disk is best-effort persistence for cross-restart survival. NFC scans are human-speed so write overlap on the same file is practically impossible; no write queue needed.

3. **`restoreArchive()`:** Already removes the completed session from `_sessions`. Now also calls `_storageService.delete()` fire-and-forget to remove the JSON file.

4. **`clearSession()`:** Also calls `_storageService.delete()` fire-and-forget.

5. **`clearAllSessions()`:** Also calls `_storageService.deleteAll()` fire-and-forget.

All disk operations are fire-and-forget unawaited, including from `restoreArchive()` (which is async but gains no benefit from awaiting the delete — the in-memory session is already removed before returning the result). Disk is best-effort persistence throughout.

## Notifier Changes: processChunk Persistence

**`RestoreNotifier.processChunk()`** currently calls `session.addChunk()` and `session.replaceChunk()` directly on the `RestoreSession` object (not via `_repository.addChunk()`). After each successful `addChunk()` or `replaceChunk()` call, `processChunk()` now also calls `_repository.persistSession(session.archiveIdString)` to trigger disk persistence. This keeps the persistence hook at the notifier level (where the mutation logic lives) rather than trying to intercept at the session level.

## Notifier Changes

**`RestoreNotifier.startScanning()`** becomes `Future<void>`. It awaits `_repository.loadFromDisk()` before setting state to `RestoreScanning`. This ensures loaded sessions appear as cards immediately when the scan screen renders. The scan screen's `_startScanning()` also becomes async: it awaits `startScanning()` before calling `_startNfcSession()`, ensuring disk sessions are loaded before NFC scanning begins. The scan screen calls `_startScanning()` inside `addPostFrameCallback`, so the async change has no impact on the build phase.

**`RestoreNotifier.deleteSession(String archiveId)`** — new method. Calls `_repository.clearSession(archiveId)` and re-emits `RestoreScanning` with updated `_getSessionInfos()`. This is what the session card delete button calls.

**`RestoreNotifier.reset()`** changes behavior:

- **Before:** Called `clearAllSessions()` (wiped all data) then set state to `RestoreInitial`.
- **After:** Only resets UI state to `RestoreInitial`. Sessions remain in memory and on disk. This is the key behavioral change.

A new `reset()` is now purely a UI/state concern, not a data-destruction action.

**Error screen "Cancel" button** currently calls `reset()`. Under the new behavior, the failed session's data persists on disk. This is intentional — the user can come back later to delete it manually, or resume scanning to replace corrupted chunks. An incomplete session on disk is harmless and the user has explicit controls to remove it.

## Scan Screen UI Changes

### On Entry

Sessions loaded from disk appear as cards immediately before any NFC scanning starts.

### Session Cards

Each card gains:
- **Delete button** — icon button to remove that individual session (with confirmation dialog)
- **Timestamp** — "last updated" displayed as absolute date/time (e.g., "Mar 23, 19:55") using Flutter's built-in `DateFormat` from `intl` (already a dependency). No relative time computation or additional packages needed.

### App Bar

- **Trash icon button** — visible when saved sessions exist. Triggers "Clear all incomplete sessions?" confirmation dialog. Calls `clearAllSessions()`.

### Back Button

- **Before:** Called `reset()` which wiped all sessions.
- **After:** Stops NFC session, navigates home. Sessions persist. No data wiped.

### Post-Restore Flow

1. Archive completes -> navigates to restore progress screen
2. User restores -> taps "Done" -> navigates home
3. Only the completed session is removed (already handled by `restoreArchive()`)
4. Other incomplete sessions survive on disk
5. User returns to "Restore Archive" -> sees remaining sessions with progress intact

## Localization

7 new l10n keys added to all 5 ARB files (en, ru, tr, uk, ka):

| Key | English |
|-----|---------|
| `clearAllSessions` | Clear all sessions |
| `clearAllSessionsConfirm` | Delete all incomplete restore sessions? |
| `deleteSession` | Delete session |
| `deleteSessionConfirm` | Delete this incomplete session? |
| `lastUpdated` | Last updated {dateTime} |
| `sessionsCleared` | All sessions cleared |
| `sessionDeleted` | Session deleted |

`{dateTime}` is formatted using `DateFormat` from the `intl` package (already a project dependency) as an absolute date/time string, localized per the user's locale.

## Out of Scope

- No separate session manager screen — management lives on the scan screen
- No session search/filter — not enough sessions to warrant it
- No session size display — cards show progress + timestamp only
- No auto-cleanup of stale sessions — user manages manually
- No migration of existing in-memory sessions — they were already ephemeral
