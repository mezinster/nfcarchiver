import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/services/file_actions_service.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

void main() {
  group('mimeTypeFor', () {
    test('resolves the type from the extension', () {
      expect(FileActionsService.mimeTypeFor('/a/b/photo.jpg'), 'image/jpeg');
    });

    test('ignores extension case', () {
      // Cameras and Windows produce IMG_0001.JPG; an octet-stream fallback
      // there would leave the Open chooser empty for an ordinary photo.
      expect(FileActionsService.mimeTypeFor('/a/IMG_0001.JPG'), 'image/jpeg');
    });

    test('falls back to octet-stream for an unknown or missing extension', () {
      expect(FileActionsService.mimeTypeFor('/a/restored_file'),
          'application/octet-stream');
      expect(FileActionsService.mimeTypeFor('/a/data.nfarx'),
          'application/octet-stream');
    });
  });

  group('openFile', () {
    test('hands the opener the path and its MIME type', () async {
      String? seenPath;
      String? seenType;
      final service = FileActionsService(
        opener: (path, {type}) async {
          seenPath = path;
          seenType = type;
          return OpenResult(type: ResultType.done);
        },
      );

      expect(await service.openFile('/a/b.pdf'), OpenOutcome.opened);
      expect(seenPath, '/a/b.pdf');
      expect(seenType, 'application/pdf');
    });

    test('reports a missing viewer app separately from other failures',
        () async {
      for (final (result, outcome) in [
        (ResultType.noAppToOpen, OpenOutcome.noApp),
        (ResultType.fileNotFound, OpenOutcome.failed),
        (ResultType.permissionDenied, OpenOutcome.failed),
        (ResultType.error, OpenOutcome.failed),
      ]) {
        final service = FileActionsService(
          opener: (path, {type}) async => OpenResult(type: result),
        );
        expect(await service.openFile('/a/b.pdf'), outcome, reason: '$result');
      }
    });

    test('a throwing platform channel is a failure, not a crash', () async {
      final service = FileActionsService(
        opener: (path, {type}) async => throw Exception('channel down'),
      );
      expect(await service.openFile('/a/b.pdf'), OpenOutcome.failed);
    });
  });

  group('shareFile', () {
    test('shares the file with an explicit MIME type', () async {
      // CLAUDE.md: an untyped XFile reaches Android as octet-stream and
      // strict receivers (Telegram) refuse to send it.
      List<XFile>? shared;
      final service =
          FileActionsService(sharer: (files) async => shared = files);

      await service.shareFile('/a/b/report.PDF');

      expect(shared, hasLength(1));
      expect(shared!.single.path, '/a/b/report.PDF');
      expect(shared!.single.mimeType, 'application/pdf');
    });

    test('an unknown extension is still typed, as octet-stream', () async {
      List<XFile>? shared;
      final service =
          FileActionsService(sharer: (files) async => shared = files);

      await service.shareFile('/a/restored_file');

      expect(shared!.single.mimeType, 'application/octet-stream');
    });
  });

  group('exportFile', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nfar-export-test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('offers the picker the bare filename and the file bytes', () async {
      final file = File(p.join(tmp.path, 'notes.txt'));
      await file.writeAsBytes([1, 2, 3]);

      String? seenName;
      Uint8List? seenBytes;
      final service = FileActionsService(
        saver: ({fileName, bytes}) async {
          seenName = fileName;
          seenBytes = bytes;
          return 'content://downloads/notes.txt';
        },
      );

      expect(await service.exportFile(file.path), isTrue);
      expect(seenName, 'notes.txt');
      expect(seenBytes, [1, 2, 3]);
    });

    test('a dismissed picker is not a save', () async {
      final file = File(p.join(tmp.path, 'notes.txt'));
      await file.writeAsBytes([1]);
      final service =
          FileActionsService(saver: ({fileName, bytes}) async => null);

      expect(await service.exportFile(file.path), isFalse);
    });
  });
}
