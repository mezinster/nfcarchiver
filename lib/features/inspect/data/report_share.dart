import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Write the inspection report to a shareable text file.
///
/// The filename carries the card UID so two dumps in one session do not
/// collide, and so a shared file is identifiable once it has left the app.
Future<File> writeReportFile(
  String report, {
  Directory? dir,
  String uid = 'card',
}) async {
  final target = dir ?? await getTemporaryDirectory();
  final file = File(p.join(target.path, 'nfar-inspect-$uid.txt'));
  await file.writeAsString(report);
  return file;
}

/// Share the report as a typed text file.
///
/// **The MIME type is explicit and must stay so.** Per CLAUDE.md, without it
/// Android's ContentResolver reports application/octet-stream and strict
/// receivers (Telegram among them) refuse to send — the same class of bug as
/// the untyped Blob that garbled restored text in the web app.
Future<void> shareReport(String report, {String uid = 'card'}) async {
  final file = await writeReportFile(report, uid: uid);
  await Share.shareXFiles([
    XFile(file.path, mimeType: lookupMimeType(file.path) ?? 'text/plain'),
  ]);
}
