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
      expect(loaded.length, 1);
    });

    test('delete non-existent session does not throw', () async {
      await expectLater(
        service.delete('non-existent-uuid'),
        completes,
      );
    });
  });
}
