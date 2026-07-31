import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_test/flutter_test.dart';
import 'package:mime/mime.dart';
import 'package:nfc_archiver/features/inspect/data/report_share.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nfar-report-test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('the shared report file is typed text/plain, never octet-stream',
      () async {
    // CLAUDE.md: without an explicit MIME type Android's ContentResolver
    // reports application/octet-stream and strict apps refuse to send. Same
    // class of bug as the untyped Blob that garbled restored text in the web
    // app.
    final f = await writeReportFile('report text', dir: tmp);
    expect(lookupMimeType(f.path), 'text/plain');
  });

  test('the filename carries the UID so two dumps do not collide', () async {
    final a = await writeReportFile('x', dir: tmp, uid: 'DEADBEEF');
    final b = await writeReportFile('y', dir: tmp, uid: 'CAFEBABE');
    expect(a.path, contains('DEADBEEF'));
    expect(a.path, isNot(equals(b.path)));
  });

  test('the report is written verbatim', () async {
    const report = 'NFC Archiver — card inspection\n\nIDENTITY\nUID DE AD';
    final f = await writeReportFile(report, dir: tmp);
    expect(await f.readAsString(), equals(report));
  });

  test('a report with no UID still produces a usable filename', () async {
    final f = await writeReportFile('x', dir: tmp);
    expect(p.basename(f.path), endsWith('.txt'));
  });
}
