import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/features/archive/data/archive_repository.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/file_manager/data/file_manager_repository.dart';
import 'package:nfc_archiver/features/file_manager/presentation/providers/file_manager_provider.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';

class _ThrowingArchiveRepo implements ArchiveRepository {
  _ThrowingArchiveRepo(this.error);
  final Object error;
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createArchive)
      return Future<ArchiveResult>.error(error);
    return super.noSuchMethod(i);
  }
}

class _ThrowingRestoreRepo implements RestoreRepository {
  _ThrowingRestoreRepo(this.error);
  final Object error;
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #restoreArchive)
      return Future<RestoreResult>.error(error);
    return super.noSuchMethod(i);
  }
}

class _ThrowingFilesRepo implements FileManagerRepository {
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #listFiles) {
      return Future<List<ArchivedFileInfo>>.error(StateError('secret-detail'));
    }
    return super.noSuchMethod(i);
  }
}

class _ReadyRestore extends RestoreNotifier {
  _ReadyRestore(RestoreRepository r) : super(repository: r);
  void ready() => state = RestoreReady(
        session: RestoreSession(archiveId: Uint8List(16)),
      );
}

class _ConfiguringArchive extends ArchiveNotifier {
  _ConfiguringArchive(ArchiveRepository r) : super(repository: r);
  void configuring() => state = const ArchiveConfiguring(
        fileName: 'f.bin',
        filePath: '/nope/f.bin',
        fileSize: 1,
        tagType: NfcTagType.ntag216,
        compress: false,
        encrypt: false,
      );
}

void main() {
  test(
      'ArchiveNotifier: an unexpected exception stores no raw text and is logged',
      () async {
    final n =
        _ConfiguringArchive(_ThrowingArchiveRepo(StateError('secret-detail')));
    n.configuring();
    await n.prepareArchive();
    final s = n.state as ArchiveError;
    expect(s.message, isNull);
    expect(log.snapshot().lastWhere((e) => e.detail != null).detail,
        contains('secret-detail'));
  });

  test('ArchiveNotifier: an ArchiveException message is kept', () async {
    final n = _ConfiguringArchive(
        _ThrowingArchiveRepo(const ArchiveException('File not found: x')));
    n.configuring();
    await n.prepareArchive();
    expect((n.state as ArchiveError).message, 'File not found: x');
  });

  test(
      'RestoreNotifier: an unexpected exception stores no raw text and is logged',
      () async {
    final n = _ReadyRestore(_ThrowingRestoreRepo(StateError('secret-detail')));
    n.ready();
    await n.restoreArchive();
    final s = n.state as RestoreError;
    expect(s.message, isNull);
    expect(log.snapshot().lastWhere((e) => e.detail != null).detail,
        contains('secret-detail'));
  });

  test('RestoreNotifier: a RestoreException message is kept', () async {
    final n =
        _ReadyRestore(_ThrowingRestoreRepo(const RestoreException('Bad data')));
    n.ready();
    await n.restoreArchive();
    expect((n.state as RestoreError).message, 'Bad data');
  });

  test(
      'FileManagerNotifier: loadFiles failure stores no raw text and is logged',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = FileManagerNotifier(container.read(_refProvider),
        repository: _ThrowingFilesRepo());
    await n.loadFiles();
    final s = n.state as FileManagerError;
    expect(s.message, isNull);
    expect(log.snapshot().lastWhere((e) => e.detail != null).detail,
        contains('secret-detail'));
  });
}

final _refProvider = Provider<Ref>((ref) => ref);
