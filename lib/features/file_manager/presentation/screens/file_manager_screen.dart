import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../shared/utils/format_utils.dart';
import '../../data/file_manager_repository.dart';
import '../providers/file_manager_provider.dart';

/// Screen for managing archived (restored) files.
class FileManagerScreen extends ConsumerWidget {
  const FileManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(fileManagerProvider);
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.invalidate(storageInfoProvider);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.archivedFiles),
          actions: [
            if (state is FileManagerLoaded && state.files.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: l10n.deleteAll,
                onPressed: () => _confirmDeleteAll(context, ref, state),
              ),
          ],
        ),
        body: _buildBody(context, ref, state),
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, WidgetRef ref, FileManagerState state) {
    final l10n = AppLocalizations.of(context)!;

    if (state is FileManagerLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state is FileManagerError) {
      return Center(child: Text(state.message));
    }

    final loaded = state as FileManagerLoaded;
    if (loaded.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noArchivedFiles,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.noArchivedFilesDesc,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6),
                  ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: loaded.files.length,
            itemBuilder: (context, index) =>
                _FileCard(file: loaded.files[index]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            l10n.storageUsage(
              loaded.storageInfo.fileCount,
              formatFileSize(loaded.storageInfo.totalBytes),
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.5),
                ),
          ),
        ),
      ],
    );
  }

  void _confirmDeleteAll(
      BuildContext context, WidgetRef ref, FileManagerLoaded state) {
    final l10n = AppLocalizations.of(context)!;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber, color: Theme.of(ctx).colorScheme.error),
        title: Text(l10n.deleteAllFiles),
        content: Text(l10n.deleteAllConfirmation(state.files.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(fileManagerProvider.notifier).deleteAllFiles();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.allFilesDeleted)),
              );
            },
            child: Text(l10n.deleteAll),
          ),
        ],
      ),
    );
  }
}

class _FileCard extends ConsumerWidget {
  const _FileCard({required this.file});

  final ArchivedFileInfo file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final dateFormat = DateFormat.yMMMd();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              _getFileIcon(file.name),
              size: 36,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatFileSize(file.size)}  •  ${l10n.modifiedDate(dateFormat.format(file.modified))}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: l10n.shareFile,
              onPressed: () => Share.shareXFiles([XFile(file.path)]),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.deleteFile,
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteFile),
        content: Text(l10n.deleteFileConfirmation(file.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(fileManagerProvider.notifier).deleteFile(file.path);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.fileDeleted(file.name))),
              );
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'mp3':
      case 'wav':
      case 'flac':
        return Icons.audio_file;
      case 'mp4':
      case 'mov':
      case 'avi':
        return Icons.video_file;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      case 'txt':
      case 'md':
        return Icons.description;
      default:
        return Icons.insert_drive_file;
    }
  }
}
