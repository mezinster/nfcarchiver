import 'dart:typed_data';

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
}
