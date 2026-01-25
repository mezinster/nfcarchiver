import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/services/chunker_service.dart';
import '../../../core/services/compression_service.dart';
import '../../../core/services/encryption_service.dart';

/// Repository for archive restoration operations.
class RestoreRepository {
  /// Singleton instance
  static final RestoreRepository instance = RestoreRepository._();

  RestoreRepository._();

  final _chunkerService = ChunkerService.instance;
  final _compressionService = CompressionService.instance;
  final _encryptionService = EncryptionService.instance;

  /// Active restore sessions by archive ID.
  final Map<String, RestoreSession> _sessions = {};

  /// Get or create a restore session for an archive.
  RestoreSession getSession(Uint8List archiveId) {
    final idString = _bytesToUuid(archiveId);
    return _sessions.putIfAbsent(
      idString,
      () => RestoreSession(archiveId: archiveId),
    );
  }

  /// Get session by ID string.
  RestoreSession? getSessionByIdString(String archiveIdString) {
    return _sessions[archiveIdString];
  }

  /// List all active sessions.
  List<RestoreSession> get activeSessions => _sessions.values.toList();

  /// Add a chunk to the appropriate session.
  ///
  /// Returns the session that received the chunk.
  RestoreSession addChunk(Chunk chunk) {
    final session = getSession(chunk.archiveId);
    session.addChunk(chunk);
    return session;
  }

  /// Restore an archive from a complete session.
  ///
  /// [session] must be complete (all chunks received).
  /// [password] is required if the archive is encrypted.
  /// [outputPath] is where to save the restored file (optional).
  Future<RestoreResult> restoreArchive({
    required RestoreSession session,
    String? password,
    String? outputPath,
  }) async {
    if (!session.isComplete) {
      throw RestoreException(
        'Cannot restore: missing ${session.missingCount} chunks',
      );
    }

    // Assemble chunks
    final chunks = session.chunks.values.toList()
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

    Uint8List data;
    try {
      data = _chunkerService.assembleChunks(chunks);
    } catch (e) {
      throw RestoreException('Failed to assemble chunks: $e');
    }

    final flags = session.flags;

    // Decrypt if encrypted
    if (NfarFlags.isEncrypted(flags)) {
      if (password == null || password.isEmpty) {
        throw RestoreException('Archive is encrypted: password required');
      }
      try {
        data = _encryptionService.decrypt(data, password);
      } catch (e) {
        throw RestoreException('Decryption failed: wrong password or corrupted data');
      }
    }

    // Decompress if compressed
    if (NfarFlags.isCompressed(flags)) {
      try {
        data = _compressionService.decompress(data);
      } catch (e) {
        throw RestoreException('Decompression failed: corrupted data');
      }
    }

    // Save to file if path provided
    String? savedPath;
    if (outputPath != null) {
      savedPath = await _saveToFile(data, outputPath);
    }

    // Clean up session
    _sessions.remove(session.archiveIdString);

    return RestoreResult(
      data: data,
      savedPath: savedPath,
      wasEncrypted: NfarFlags.isEncrypted(flags),
      wasCompressed: NfarFlags.isCompressed(flags),
      totalChunks: session.totalChunks,
    );
  }

  /// Save data to the downloads directory.
  Future<String> saveToDownloads(Uint8List data, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory(path.join(dir.path, 'NFC_Archives'));
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }

    var filePath = path.join(downloadsDir.path, fileName);

    // Handle duplicate names
    int counter = 1;
    while (await File(filePath).exists()) {
      final ext = path.extension(fileName);
      final name = path.basenameWithoutExtension(fileName);
      filePath = path.join(downloadsDir.path, '$name ($counter)$ext');
      counter++;
    }

    final file = File(filePath);
    await file.writeAsBytes(data);
    return filePath;
  }

  Future<String> _saveToFile(Uint8List data, String filePath) async {
    final file = File(filePath);
    await file.writeAsBytes(data);
    return filePath;
  }

  /// Clear a specific session.
  void clearSession(String archiveIdString) {
    _sessions.remove(archiveIdString);
  }

  /// Clear all sessions.
  void clearAllSessions() {
    _sessions.clear();
  }

  String _bytesToUuid(Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}

/// Session for collecting chunks of an archive.
class RestoreSession {
  RestoreSession({required this.archiveId});

  final Uint8List archiveId;
  final Map<int, Chunk> _chunks = {};
  int? _totalChunks;
  int _flags = 0;

  /// All received chunks.
  Map<int, Chunk> get chunks => Map.unmodifiable(_chunks);

  /// Total chunks expected.
  int get totalChunks => _totalChunks ?? 0;

  /// Number of chunks received.
  int get receivedCount => _chunks.length;

  /// Number of missing chunks.
  int get missingCount => totalChunks - receivedCount;

  /// Progress (0.0 to 1.0).
  double get progress => totalChunks > 0 ? receivedCount / totalChunks : 0.0;

  /// Whether all chunks have been received.
  bool get isComplete => totalChunks > 0 && receivedCount >= totalChunks;

  /// Flags from the archive.
  int get flags => _flags;

  /// Whether the archive is encrypted.
  bool get isEncrypted => NfarFlags.isEncrypted(_flags);

  /// Whether the archive is compressed.
  bool get isCompressed => NfarFlags.isCompressed(_flags);

  /// Archive ID as UUID string.
  String get archiveIdString {
    final hex = archiveId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// List of missing chunk indices.
  List<int> get missingIndices {
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!_chunks.containsKey(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  /// Add a chunk to the session.
  ///
  /// Returns true if this is a new chunk, false if duplicate.
  bool addChunk(Chunk chunk) {
    // Update total chunks and flags from any chunk
    _totalChunks ??= chunk.totalChunks;
    _flags = chunk.flags;

    // Check if already received
    if (_chunks.containsKey(chunk.chunkIndex)) {
      return false;
    }

    _chunks[chunk.chunkIndex] = chunk;
    return true;
  }

  /// Replace a chunk (for rescanning corrupted chunks).
  void replaceChunk(Chunk chunk) {
    _chunks[chunk.chunkIndex] = chunk;
  }

  /// Check if a chunk index has been received.
  bool hasChunk(int index) => _chunks.containsKey(index);

  /// Validate all chunks and return indices of corrupted ones.
  List<int> getCorruptedChunkIndices() {
    final corrupted = <int>[];
    for (final entry in _chunks.entries) {
      if (!ChunkerService.instance.validateChunk(entry.value)) {
        corrupted.add(entry.key);
      }
    }
    return corrupted;
  }

  /// Check if all chunks pass CRC validation.
  bool get allChunksValid => getCorruptedChunkIndices().isEmpty;
}

/// Result of archive restoration.
class RestoreResult {
  const RestoreResult({
    required this.data,
    this.savedPath,
    required this.wasEncrypted,
    required this.wasCompressed,
    required this.totalChunks,
  });

  final Uint8List data;
  final String? savedPath;
  final bool wasEncrypted;
  final bool wasCompressed;
  final int totalChunks;

  int get dataSize => data.length;
}

/// Exception during restore operations.
class RestoreException implements Exception {
  const RestoreException(this.message);

  final String message;

  @override
  String toString() => 'RestoreException: $message';
}
