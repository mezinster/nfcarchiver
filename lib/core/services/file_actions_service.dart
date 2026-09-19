import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// What happened when the system was asked to open a file.
enum OpenOutcome { opened, noApp, failed }

/// Seam over `OpenFilex.open`, so the outcome mapping is testable without a
/// platform channel.
typedef FileOpener = Future<OpenResult> Function(String path, {String? type});

/// Seam over `FilePicker.saveFile`. Resolves to null when the picker was
/// dismissed.
typedef FileSaver = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
});

/// Seam over `SharePlus.instance.share`.
typedef FileSharer = Future<void> Function(List<XFile> files);

/// Gets restored files out of the app's private `NFC_Archives` directory,
/// which no other app can see: open them in place with a viewer, copy them
/// to a location the user picks, or hand them to the share sheet.
///
/// Every file handed to another app carries an explicit MIME type resolved
/// from its extension ([mimeTypeFor]). Without it Android's ContentResolver
/// reports `application/octet-stream`: the `ACTION_VIEW` chooser offers
/// nothing useful, and strict share targets such as Telegram refuse to send.
class FileActionsService {
  FileActionsService({FileOpener? opener, FileSaver? saver, FileSharer? sharer})
      : _opener = opener ?? _platformOpen,
        _saver = saver ?? _platformSave,
        _sharer = sharer ?? _platformShare;

  final FileOpener _opener;
  final FileSaver _saver;
  final FileSharer _sharer;

  static Future<void> _platformShare(List<XFile> files) =>
      SharePlus.instance.share(ShareParams(files: files));

  static Future<OpenResult> _platformOpen(String path, {String? type}) =>
      OpenFilex.open(path, type: type);

  static Future<Uri?> _platformSave({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) =>
      FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType);

  /// MIME type for [path] from its extension, `application/octet-stream`
  /// when the extension is unknown or missing.
  static String mimeTypeFor(String path) =>
      lookupMimeType(path.toLowerCase()) ?? 'application/octet-stream';

  /// Open [filePath] with whatever app handles its type.
  Future<OpenOutcome> openFile(String filePath) async {
    try {
      final result = await _opener(filePath, type: mimeTypeFor(filePath));
      return switch (result.type) {
        ResultType.done => OpenOutcome.opened,
        ResultType.noAppToOpen => OpenOutcome.noApp,
        _ => OpenOutcome.failed,
      };
    } catch (_) {
      return OpenOutcome.failed;
    }
  }

  /// Hand [filePath] to the system share sheet, typed.
  Future<void> shareFile(String filePath) =>
      _sharer([XFile(filePath, mimeType: mimeTypeFor(filePath))]);

  /// Let the user copy [filePath] somewhere other apps can reach, through the
  /// system "save as" picker (Downloads by default). Needs no storage
  /// permission. Returns false when the picker was dismissed.
  Future<bool> exportFile(String filePath) async {
    final saved = await _saver(
      fileName: p.basename(filePath),
      bytes: await File(filePath).readAsBytes(),
      // file_picker would otherwise default to application/octet-stream.
      mimeType: mimeTypeFor(filePath),
    );
    return saved != null;
  }
}

final fileActionsProvider =
    Provider<FileActionsService>((ref) => FileActionsService());
