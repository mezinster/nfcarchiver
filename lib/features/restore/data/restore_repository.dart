import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/services/chunker_service.dart';
import '../../../core/services/compression_service.dart';
import '../../../core/services/encryption_service.dart';
import 'session_storage_service.dart';

/// Repository for archive restoration operations.
class RestoreRepository {
  /// Singleton instance
  static final RestoreRepository instance = RestoreRepository._();

  RestoreRepository._();

  final _chunkerService = ChunkerService.instance;
  final _compressionService = CompressionService.instance;
  final _encryptionService = EncryptionService.instance;
  final _storageService = SessionStorageService.instance;

  /// Active restore sessions by archive ID.
  final Map<String, RestoreSession> _sessions = {};

  /// Load sessions from disk into memory.
  /// Existing in-memory sessions take precedence over disk versions.
  Future<void> loadFromDisk() async {
    final diskSessions = await _storageService.loadAll();
    for (final session in diskSessions) {
      _sessions.putIfAbsent(session.archiveIdString, () => session);
    }
  }

  /// Persist a session to disk (fire-and-forget).
  void persistSession(String archiveIdString) {
    final session = _sessions[archiveIdString];
    if (session != null) {
      _storageService.save(session);
    }
  }

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
      } catch (_) {
        throw RestoreException(
          'Decryption failed: wrong password or corrupted data',
        );
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

    // Extract filename metadata
    String? originalFileName;
    final metadataResult = _extractFilenameMetadata(data);
    if (metadataResult != null) {
      originalFileName = metadataResult.fileName;
      data = metadataResult.data;
    }

    // Save to file if path provided
    String? savedPath;
    if (outputPath != null) {
      savedPath = await _saveToFile(data, outputPath);
    }

    // Clean up session
    _sessions.remove(session.archiveIdString);
    _storageService.delete(session.archiveIdString);

    return RestoreResult(
      data: data,
      savedPath: savedPath,
      wasEncrypted: NfarFlags.isEncrypted(flags),
      wasCompressed: NfarFlags.isCompressed(flags),
      totalChunks: session.totalChunks,
      originalFileName: originalFileName,
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
    _storageService.delete(archiveIdString);
    _sessions.remove(archiveIdString);
  }

  /// Clear all sessions.
  void clearAllSessions() {
    _storageService.deleteAll();
    _sessions.clear();
  }

  String _bytesToUuid(Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Extract filename metadata from data.
  /// Format: [2-byte length (big-endian)][UTF-8 filename bytes][original data]
  /// Returns (filename, remaining data) or null if invalid.
  ({String fileName, Uint8List data})? _extractFilenameMetadata(Uint8List data) {
    if (data.length < 2) return null;

    final filenameLength = (data[0] << 8) | data[1];
    if (filenameLength == 0 || filenameLength > 255) return null;
    if (data.length < 2 + filenameLength) return null;

    try {
      final filenameBytes = data.sublist(2, 2 + filenameLength);
      final fileName = utf8.decode(filenameBytes);
      final remainingData = Uint8List.sublistView(data, 2 + filenameLength);
      return (fileName: fileName, data: remainingData);
    } catch (_) {
      return null;
    }
  }
}

/// Session for collecting chunks of an archive.
class RestoreSession {
  RestoreSession({required this.archiveId})
      : createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  RestoreSession._fromJson({
    required this.archiveId,
    required this.createdAt,
    required this.updatedAt,
    required int? totalChunks,
    required int flags,
  })  : _totalChunks = totalChunks,
        _flags = flags;

  final Uint8List archiveId;
  final Map<int, Chunk> _chunks = {};
  int? _totalChunks;
  int _flags = 0;

  /// Timestamp when this session was created.
  final DateTime createdAt;

  /// Timestamp when this session was last updated.
  DateTime updatedAt;

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
    updatedAt = DateTime.now();
    return true;
  }

  /// Replace a chunk (for rescanning corrupted chunks).
  void replaceChunk(Chunk chunk) {
    _chunks[chunk.chunkIndex] = chunk;
    updatedAt = DateTime.now();
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

  /// Serialize this session to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    final chunksMap = <String, String>{};
    for (final entry in _chunks.entries) {
      chunksMap[entry.key.toString()] = base64Encode(entry.value.toBytes());
    }
    return {
      'archiveId': archiveIdString,
      'archiveIdBytes': base64Encode(archiveId),
      'totalChunks': totalChunks,
      'flags': _flags,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'chunks': chunksMap,
    };
  }

  /// Reconstruct a [RestoreSession] from a JSON-compatible map.
  factory RestoreSession.fromJson(Map<String, dynamic> json) {
    final archiveId = base64Decode(json['archiveIdBytes'] as String);
    final totalChunks = json['totalChunks'] as int;
    final flags = json['flags'] as int;
    final createdAt = DateTime.parse(json['createdAt'] as String);
    final updatedAt = DateTime.parse(json['updatedAt'] as String);

    final session = RestoreSession._fromJson(
      archiveId: Uint8List.fromList(archiveId),
      createdAt: createdAt,
      updatedAt: updatedAt,
      totalChunks: totalChunks > 0 ? totalChunks : null,
      flags: flags,
    );

    final chunksMap = json['chunks'] as Map<String, dynamic>;
    for (final entry in chunksMap.entries) {
      final index = int.parse(entry.key);
      final chunkBytes = base64Decode(entry.value as String);
      final chunk = Chunk.fromBytes(Uint8List.fromList(chunkBytes));
      session._chunks[index] = chunk;
    }

    return session;
  }
}

/// Result of archive restoration.
class RestoreResult {
  const RestoreResult({
    required this.data,
    this.savedPath,
    required this.wasEncrypted,
    required this.wasCompressed,
    required this.totalChunks,
    this.originalFileName,
  });

  final Uint8List data;
  final String? savedPath;
  final bool wasEncrypted;
  final bool wasCompressed;
  final int totalChunks;
  /// Original filename extracted from archive metadata, if available.
  final String? originalFileName;

  int get dataSize => data.length;
}

/// Exception during restore operations.
class RestoreException implements Exception {
  const RestoreException(this.message);

  final String message;

  @override
  String toString() => 'RestoreException: $message';
}
