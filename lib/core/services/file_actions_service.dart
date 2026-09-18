import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// What happened when the system was asked to open a file.
enum OpenOutcome { opened, noApp, failed }

/// Seam over `OpenFilex.open`, so the outcome mapping is testable without a
/// platform channel.
typedef FileOpener = Future<OpenResult> Function(String path, {String? type});

/// Seam over `FilePicker.saveFile`. Resolves to null when the picker was
/// dismissed.
typedef FileSaver = Future<String?> Function({
  String? fileName,
  Uint8List? bytes,
});

/// Gets restored files out of the app's private `NFC_Archives` directory,
/// which no other app can see: open them in place with a viewer, or copy them
/// to a location the user picks.
///
/// Every file handed to another app carries an explicit MIME type resolved
/// from its extension ([mimeTypeFor]). Without it Android's ContentResolver
/// reports `application/octet-stream`, and the `ACTION_VIEW` chooser offers
/// nothing useful — the same reason every `Share.shareXFiles` call is typed.
class FileActionsService {
  FileActionsService({FileOpener? opener, FileSaver? saver})
      : _opener = opener ?? _platformOpen,
        _saver = saver ?? _platformSave;

  final FileOpener _opener;
  final FileSaver _saver;

  static Future<OpenResult> _platformOpen(String path, {String? type}) =>
      OpenFilex.open(path, type: type);

  static Future<String?> _platformSave({String? fileName, Uint8List? bytes}) =>
      FilePicker.saveFile(fileName: fileName, bytes: bytes);

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

  /// Let the user copy [filePath] somewhere other apps can reach, through the
  /// system "save as" picker (Downloads by default). Needs no storage
  /// permission. Returns false when the picker was dismissed.
  Future<bool> exportFile(String filePath) async {
    final saved = await _saver(
      fileName: p.basename(filePath),
      bytes: await File(filePath).readAsBytes(),
    );
    return saved != null;
  }
}

final fileActionsProvider =
    Provider<FileActionsService>((ref) => FileActionsService());
