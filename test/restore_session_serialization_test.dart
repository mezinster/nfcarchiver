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
