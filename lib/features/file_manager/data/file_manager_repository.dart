import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Lightweight storage statistics.
class StorageInfo {
  const StorageInfo({required this.fileCount, required this.totalBytes});

  final int fileCount;
  final int totalBytes;

  static const empty = StorageInfo(fileCount: 0, totalBytes: 0);
}

/// Information about a single archived file.
class ArchivedFileInfo {
  const ArchivedFileInfo({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final int size;
  final DateTime modified;
}

/// Repository for managing restored files in the NFC_Archives directory.
class FileManagerRepository {
  static final FileManagerRepository instance = FileManagerRepository._();

  FileManagerRepository._();

  Future<Directory> _getArchivesDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(path.join(dir.path, 'NFC_Archives'));
  }

  /// Get storage info (file count + total size).
  Future<StorageInfo> getStorageInfo() async {
    final dir = await _getArchivesDir();
    if (!await dir.exists()) return StorageInfo.empty;

    int count = 0;
    int totalBytes = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        count++;
        totalBytes += await entity.length();
      }
    }
    return StorageInfo(fileCount: count, totalBytes: totalBytes);
  }

  /// List all archived files, sorted newest-first.
  Future<List<ArchivedFileInfo>> listFiles() async {
    final dir = await _getArchivesDir();
    if (!await dir.exists()) return [];

    final files = <ArchivedFileInfo>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        files.add(ArchivedFileInfo(
          name: path.basename(entity.path),
          path: entity.path,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  /// Delete a single file. Returns true if deleted.
  Future<bool> deleteFile(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  /// Delete all archived files. Returns count of deleted files.
  Future<int> deleteAllFiles() async {
    final dir = await _getArchivesDir();
    if (!await dir.exists()) return 0;

    int count = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        await entity.delete();
        count++;
      }
    }
    return count;
  }
}
