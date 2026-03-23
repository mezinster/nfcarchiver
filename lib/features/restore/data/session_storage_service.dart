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
