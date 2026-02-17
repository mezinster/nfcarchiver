import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  const FileManagerError(this.message);

  final String message;
}

/// Provider for the file manager screen.
final fileManagerProvider =
    StateNotifierProvider.autoDispose<FileManagerNotifier, FileManagerState>(
  (ref) => FileManagerNotifier(ref),
);

class FileManagerNotifier extends StateNotifier<FileManagerState> {
  FileManagerNotifier(this._ref) : super(const FileManagerLoading()) {
    loadFiles();
  }

  final Ref _ref;
  final _repo = FileManagerRepository.instance;

  Future<void> loadFiles() async {
    state = const FileManagerLoading();
    try {
      final files = await _repo.listFiles();
      final storageInfo = await _repo.getStorageInfo();
      state = FileManagerLoaded(files: files, storageInfo: storageInfo);
    } catch (e) {
      state = FileManagerError(e.toString());
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
