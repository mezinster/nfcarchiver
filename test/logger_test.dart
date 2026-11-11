import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/log/logger.dart';

void main() {
  setUp(() {
    log
      ..clear()
      ..minLevel = LogLevel.debug
      ..mirrorToConsole = false;
  });

  test('entries are recorded with a monotonic sequence', () {
    log.info('device', 'first');
    log.info('device', 'second');
    final s = log.snapshot();
    expect(s.length, 2);
    expect(s[1].seq, greaterThan(s[0].seq));
  });

  test('the level filter drops quieter entries', () {
    log.minLevel = LogLevel.warn;
    log.debug('device', 'noise');
    log.info('device', 'noise');
    log.warn('device', 'kept');
    log.error('device', 'kept');
    expect(log.snapshot().length, 2);
  });

  test('the buffer is bounded and keeps the NEWEST entries', () {
    // A long hardware session must not grow memory without limit, and when it
    // overflows the recent entries are the ones worth having.
    for (var i = 0; i < Logger.capacity + 50; i++) {
      log.debug('frame', 'entry $i');
    }
    final s = log.snapshot();
    expect(s.length, Logger.capacity);
    expect(s.last.message, 'entry ${Logger.capacity + 49}');
  });

  test('a formatted line carries time, level, scope, message and data', () {
    log.warn('ble', 'link dropped', {'deviceId': 'AA:BB', 'attempt': 2});
    final line = log.snapshot().single.format();
    expect(line, contains('WARN'));
    expect(line, contains('[ble]'));
    expect(line, contains('link dropped'));
    expect(line, contains('deviceId=AA:BB'));
    expect(line, contains('attempt=2'));
  });

  group('hexDump', () {
    test('renders uppercase, space-separated bytes', () {
      expect(hexDump(Uint8List.fromList([0x11, 0xef, 0x03, 0xe8])),
          '11 EF 03 E8');
    });

    test('truncates long buffers but states the true length', () {
      // A 752-byte card dump must not bury the line it appears on, but the
      // real size still has to be visible.
      final out = hexDump(Uint8List(200), max: 8);
      expect(out, contains('…'));
      expect(out, contains('200 B'));
    });

    test('an empty buffer renders as empty, not as an error', () {
      expect(hexDump(Uint8List(0)), '');
    });
  });

  test('report() records an error with PlatformException fields on separate lines', () {
    log.report(
      'nfc.read',
      'read failed',
      PlatformException(
        code: 'Error Domain=NFCError Code=403 "x"',
        message: 'NFCError',
        details: 'Stacktrace: ["0 Runner"]',
      ),
    );
    final e = log.snapshot().single;
    expect(e.level, LogLevel.error);
    expect(e.detail, contains('code: Error Domain=NFCError Code=403'));
    expect(e.detail, contains('message: NFCError'));
    expect(e.detail, contains('details: Stacktrace:'));
  });

  test('formatFull indents detail under the line', () {
    log.error('s', 'boom', null, 'a\nb');
    final e = log.snapshot().single;
    expect(e.format(), isNot(contains('\n')));
    final lines = e.formatFull().split('\n');
    expect(lines[1], startsWith('    '));
    expect(lines[2], startsWith('    '));
  });

  test('detail is capped at maxDetailChars', () {
    log.report('s', 'big', _Huge());
    final d = log.snapshot().single.detail!;
    expect(d.length, lessThanOrEqualTo(Logger.maxDetailChars + 20));
    expect(d, endsWith('[truncated]'));
  });

  test('listeners receive entries after the level filter and a throwing listener is ignored', () {
    final got = <LogEntry>[];
    void thrower(LogEntry _) => throw StateError('bad');
    log
      ..addListener(thrower)
      ..addListener(got.add);
    addTearDown(() {
      log
        ..removeListener(thrower)
        ..removeListener(got.add);
    });
    log.minLevel = LogLevel.info;
    log.debug('s', 'd');
    log.info('s', 'i');
    expect(got.length, 1);
    expect(got.single.message, 'i');
  });

  test('report() never writes a FileSystemException path into the log', () {
    log.report(
      's',
      'open failed',
      const PathNotFoundException('/secret/dir/tax-return-2026.pdf',
          OSError('No such file or directory', 2), 'Cannot open file'),
    );
    final d = log.snapshot().last.detail!;
    expect(d, contains('PathNotFoundException'));
    expect(d, contains('Cannot open file'));
    expect(d, contains('errno = 2'));
    expect(d, isNot(contains('tax-return')));
    expect(d, isNot(contains('/secret')));
  });
}

class _Huge {
  @override
  String toString() => 'x' * 100000;
}
