import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/log/diagnostics.dart';
import 'package:nfc_archiver/core/log/logger.dart';

void main() {
  late FlutterExceptionHandler? savedOnError;
  late void Function(FlutterErrorDetails) savedPresent;
  late ErrorCallback? savedPlatform;
  late int presented;

  setUp(() {
    savedOnError = FlutterError.onError;
    savedPresent = FlutterError.presentError;
    savedPlatform = PlatformDispatcher.instance.onError;
    presented = 0;
    FlutterError.presentError = (_) => presented++;
    log.clear();
    log.mirrorToConsole = false;
    installErrorHooks(log);
  });

  tearDown(() {
    FlutterError.onError = savedOnError;
    FlutterError.presentError = savedPresent;
    PlatformDispatcher.instance.onError = savedPlatform;
    log.mirrorToConsole = true;
    log.clear();
  });

  test('FlutterError.onError logs and still presents the error', () {
    FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'), stack: StackTrace.current));
    final entries = log.snapshot();
    expect(entries, hasLength(1));
    expect(entries.single.level, LogLevel.error);
    expect(entries.single.detail, contains('boom'));
    expect(presented, 1);
  });

  test('PlatformDispatcher error hook reports and returns true', () {
    final handled = PlatformDispatcher.instance.onError!(
        StateError('async boom'), StackTrace.current);
    expect(handled, isTrue);
    expect(log.snapshot().single.detail, contains('async boom'));
  });

  test('a listener that throws inside the hook does not recurse', () {
    void bad(LogEntry _) => throw StateError('listener');
    log.addListener(bad);
    addTearDown(() => log.removeListener(bad));
    FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'), stack: StackTrace.current));
    expect(log.snapshot(), hasLength(1));
  });

  test('a listener that re-enters the hook is dropped, not recursed', () {
    var calls = 0;
    void reenter(LogEntry _) {
      calls++;
      FlutterError
          .onError!(FlutterErrorDetails(exception: StateError('inner')));
    }

    log.addListener(reenter);
    addTearDown(() => log.removeListener(reenter));
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('outer')));
    expect(calls, 1);
    expect(log.snapshot(), hasLength(1));
  });

  test('sessionHeader format', () {
    expect(
      sessionHeader(
          version: '1.2.1', build: '19', os: 'ios 18.5', locale: 'en-US'),
      '=== NFC Archiver 1.2.1 (19) · ios 18.5 · en-US · session start ===',
    );
  });
}
