import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';

/// Preparing reads and chunks the file asynchronously. A share arriving in
/// that window selects a new file; the finished preparation of the old one
/// used to land on top of it.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('prepare'));
  tearDown(() => dir.deleteSync(recursive: true));

  ArchiveNotifier configured() {
    final file = File('${dir.path}/a.bin')..writeAsBytesSync(List.filled(500, 7));
    return ArchiveNotifier()
      ..selectFile(filePath: file.path, fileName: 'a.bin', fileSize: 500)
      ..configure(tagType: NfcTagType.ntag216, compress: false, encrypt: false);
  }

  test('an undisturbed preparation becomes the state', () async {
    final n = configured();
    expect(await n.prepareArchive(), isTrue);
    expect(n.state, isA<ArchiveReady>());
  });

  test('a selection made while preparing is not overwritten', () async {
    final n = configured();
    final preparing = n.prepareArchive();
    expect(n.state, isA<ArchivePreparing>());

    n.selectFile(filePath: '${dir.path}/b.bin', fileName: 'b.bin', fileSize: 9);

    expect(await preparing, isFalse);
    final s = n.state;
    expect(s, isA<ArchiveFileSelected>());
    expect((s as ArchiveFileSelected).fileName, 'b.bin');
  });

  test('a failed preparation does not overwrite a newer selection either',
      () async {
    final n = ArchiveNotifier()
      ..selectFile(
          filePath: '${dir.path}/missing.bin', fileName: 'missing.bin', fileSize: 5)
      ..configure(tagType: NfcTagType.ntag216, compress: false, encrypt: false);
    final preparing = n.prepareArchive();
    n.reset();

    expect(await preparing, isFalse);
    expect(n.state, isA<ArchiveInitial>());
  });
}
