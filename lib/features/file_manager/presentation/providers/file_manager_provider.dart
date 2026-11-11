import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/log/logger.dart';
import '../../data/file_manager_repository.dart';

/// Lightweight provider for storage info, used by the home screen indicator.
/// Uses autoDispose so it re-fetches when the home screen is navigated to.
final storageInfoProvider = FutureProvider.autoDispose<StorageInfo>((ref) {
  return FileManagerRepository.instance.getStorageInfo();
});

/// State for the file manager screen.
sealed class FileManagerState {
  const FileManagerState();
}

class FileManagerLoading extends FileManagerState {
  const FileManagerLoading();
}

class FileManagerLoaded extends FileManagerState {
  const FileManagerLoaded({
    required this.files,
    required this.storageInfo,
  });

  final List<ArchivedFileInfo> files;
  final StorageInfo storageInfo;
}

class FileManagerError extends FileManagerState {
  const FileManagerError([this.message]);

  /// Always null today: nothing app-authored is thrown while listing files.
  final String? message;
}

/// Provider for the file manager screen.
final fileManagerProvider =
    StateNotifierProvider.autoDispose<FileManagerNotifier, FileManagerState>(
  (ref) => FileManagerNotifier(ref),
);

class FileManagerNotifier extends StateNotifier<FileManagerState> {
  FileManagerNotifier(this._ref, {FileManagerRepository? repository})
      : _repo = repository ?? FileManagerRepository.instance,
        super(const FileManagerLoading()) {
    loadFiles();
  }

  final Ref _ref;
  final FileManagerRepository _repo;

  Future<void> loadFiles() async {
    state = const FileManagerLoading();
    try {
      final files = await _repo.listFiles();
      final storageInfo = await _repo.getStorageInfo();
      state = FileManagerLoaded(files: files, storageInfo: storageInfo);
    } catch (e, st) {
      log.report('files', 'load files failed', e, st);
      state = const FileManagerError();
    }
  }

  Future<void> deleteFile(String path) async {
    await _repo.deleteFile(path);
    _ref.invalidate(storageInfoProvider);
    await loadFiles();
  }

  Future<void> deleteAllFiles() async {
    await _repo.deleteAllFiles();
    _ref.invalidate(storageInfoProvider);
    await loadFiles();
  }
}
