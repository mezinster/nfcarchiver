import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/log/diagnostics_file.dart';
import 'package:nfc_archiver/core/log/logger.dart';

LogEntry entry(int seq, LogLevel level, [String message = 'm']) => LogEntry(
      seq: seq,
      at: DateTime.utc(2026, 11, 11, 10, 0, 0),
      level: level,
      scope: 'test',
      message: message,
    );

void main() {
  late Directory tmp;
  late Directory dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('diag_test');
    dir = Directory('${tmp.path}/logs');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File cur() => File('${dir.path}/diagnostics.log');

  test('debug entries are not persisted; info+ are', () async {
    final f = DiagnosticsFile(dir: dir);
    f.add(entry(0, LogLevel.debug, 'dbg-secret'));
    f.add(entry(1, LogLevel.info, 'info-line'));
    await f.flush();
    final all = await f.readAll();
    expect(all, contains('info-line'));
    expect(all, isNot(contains('dbg-secret')));
  });

  test('an error entry is on disk without waiting for the timer', () async {
    final f = DiagnosticsFile(dir: dir, flushEvery: const Duration(hours: 1));
    f.add(entry(0, LogLevel.error, 'boom'));
    // Poll with a deadline: the flush needs several dart:io round trips, more
    // than pumpEventQueue's fixed number of loop turns.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var text = '';
    while (DateTime.now().isBefore(deadline)) {
      if (cur().existsSync()) text = cur().readAsStringSync();
      if (text.contains('boom')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(text, contains('boom'));
  });

  test('rotates at maxBytes keeping one previous file', () async {
    final f = DiagnosticsFile(dir: dir, maxBytes: 1024);
    for (var i = 0; i < 100; i++) {
      f.add(entry(i, LogLevel.info, 'n${i.toString().padLeft(3, '0')}'));
    }
    await f.flush();
    expect(cur().existsSync(), isTrue);
    expect(File('${dir.path}/diagnostics.1.log').existsSync(), isTrue);
    expect(File('${dir.path}/diagnostics.2.log').existsSync(), isFalse);
    expect(cur().lengthSync(), lessThan(1024 + 100));
    final nums = RegExp(r'n(\d{3})')
        .allMatches(await f.readAll())
        .map((m) => int.parse(m.group(1)!))
        .toList();
    expect(nums, isNotEmpty);
    expect(nums, orderedEquals([...nums]..sort()));
    expect(nums.last, 99);
  });

  test('clear while a flush is pending leaves nothing behind', () async {
    final f = DiagnosticsFile(dir: dir, flushEvery: const Duration(hours: 1));
    for (var i = 0; i < 5; i++) {
      f.add(entry(i, LogLevel.info));
    }
    await f.clear();
    await f.flush();
    expect(await f.readAll(), isEmpty);
  });

  test('exportTo writes header then content, header alone when empty',
      () async {
    final f = DiagnosticsFile(dir: dir);
    final out = Directory('${tmp.path}/out')..createSync();
    final now = DateTime(2026, 11, 11, 9, 8, 7);
    final empty = await f.exportTo(out, now: now, header: 'HDR');
    final name = empty.path.split(Platform.pathSeparator).last;
    expect(name, matches(RegExp(r'^nfc-archiver-log-\d{8}-\d{6}\.txt$')));
    expect(name, 'nfc-archiver-log-20261111-090807.txt');
    expect(empty.readAsStringSync(), 'HDR\n');

    f.add(entry(0, LogLevel.info, 'content-line'));
    final full = await f.exportTo(out, now: now, header: 'HDR');
    final text = full.readAsStringSync();
    expect(text, startsWith('HDR\n'));
    expect(text, contains('content-line'));
  });

  test('an unwritable directory degrades instead of throwing', () async {
    final file = File('${tmp.path}/f')..createSync();
    final f = DiagnosticsFile(dir: Directory('${file.path}/logs'));
    f.add(entry(0, LogLevel.error, 'x'));
    await f.flush();
    expect(f.degraded, isTrue);
    expect(await f.readAll(), isEmpty);
  });
}
