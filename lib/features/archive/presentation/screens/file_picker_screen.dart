import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/archive_provider.dart';

/// Provider for tracking the input mode (file or text).
final inputModeProvider = StateProvider<InputMode>((ref) => InputMode.file);

enum InputMode { file, text }

/// Screen for selecting a file or entering text to archive.
class FilePickerScreen extends ConsumerStatefulWidget {
  const FilePickerScreen({super.key});

  @override
  ConsumerState<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends ConsumerState<FilePickerScreen> {
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(archiveProvider);
    final inputMode = ref.watch(inputModeProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.selectFile),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Mode selector
            SegmentedButton<InputMode>(
              segments: [
                ButtonSegment(
                  value: InputMode.file,
                  label: Text(l10n.file),
                  icon: const Icon(Icons.insert_drive_file),
                ),
                ButtonSegment(
                  value: InputMode.text,
                  label: Text(l10n.text),
                  icon: const Icon(Icons.text_fields),
                ),
              ],
              selected: {inputMode},
              onSelectionChanged: (selected) {
                ref.read(inputModeProvider.notifier).state = selected.first;
                ref.read(archiveProvider.notifier).reset();
                _textController.clear();
              },
            ),

            const SizedBox(height: 16),

            // Content based on mode
            Expanded(
              child: inputMode == InputMode.file
                  ? _buildFileMode(context, state)
                  : _buildTextMode(context, state),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileMode(BuildContext context, ArchiveState state) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // File picker card
        Card(
          child: InkWell(
            onTap: () => _pickFile(context),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.upload_file,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.tapToSelectFile,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.chooseFileToArchive,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),

        // Selected file info
        if (state is ArchiveFileSelected) ...[
          _FileInfoCard(
            fileName: state.fileName,
            fileSize: state.fileSize,
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => context.go('/archive/settings'),
            icon: const Icon(Icons.settings),
            label: Text(l10n.configureArchive),
          ),
        ],
      ],
    );
  }

  Widget _buildTextMode(BuildContext context, ArchiveState state) {
    final l10n = AppLocalizations.of(context)!;
    final textBytes = utf8.encode(_textController.text);
    final byteSize = textBytes.length;
    final hasText = _textController.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Text input card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.text_snippet,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.enterTextToArchive,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _textController,
                  maxLines: 8,
                  minLines: 4,
                  decoration: InputDecoration(
                    hintText: l10n.typeYourTextHere,
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                // Live byte counter
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.charactersCount(_textController.text.length),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6),
                          ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        l10n.bytesUnit(byteSize),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const Spacer(),

        // Configure button
        if (hasText)
          FilledButton.icon(
            onPressed: () {
              ref.read(archiveProvider.notifier).selectText(
                    text: _textController.text,
                    textSize: byteSize,
                  );
              context.go('/archive/settings');
            },
            icon: const Icon(Icons.settings),
            label: Text(l10n.configureArchive),
          ),
      ],
    );
  }

  Future<void> _pickFile(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.couldNotAccessFile)),
          );
        }
        return;
      }

      // Get file size
      final fileInfo = File(file.path!);
      final size = await fileInfo.length();

      ref.read(archiveProvider.notifier).selectFile(
            filePath: file.path!,
            fileName: file.name,
            fileSize: size,
          );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorSelectingFile(e.toString()))),
        );
      }
    }
  }
}

class _FileInfoCard extends StatelessWidget {
  const _FileInfoCard({
    required this.fileName,
    required this.fileSize,
  });

  final String fileName;
  final int fileSize;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _getFileIcon(fileName),
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatFileSize(fileSize),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
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

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
