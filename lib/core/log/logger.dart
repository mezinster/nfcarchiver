import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

/// Structured logging for the app.
///
/// Two destinations at once, on purpose:
///
/// * `dart:developer log()`, so entries reach `flutter run` and `adb logcat -s
///   flutter` — which is how a hardware session is actually debugged.
/// * an in-memory ring buffer, so a Log screen (and copy/share for bug
///   reports) can be added later without re-instrumenting anything.
///
/// Mirrors the web app's `src/log/logger.ts`. That logger is what made this
/// morning's Web NFC freeze diagnosable at all, and the Flutter app had no
/// equivalent before the Chameleon work needed one.
enum LogLevel { debug, info, warn, error }

extension LogLevelOrder on LogLevel {
  int get rank => switch (this) {
        LogLevel.debug => 0,
        LogLevel.info => 1,
        LogLevel.warn => 2,
        LogLevel.error => 3,
      };

  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };
}

class LogEntry {
  const LogEntry({
    required this.seq,
    required this.at,
    required this.level,
    required this.scope,
    required this.message,
    this.data,
    this.detail,
  });

  final int seq;
  final DateTime at;
  final LogLevel level;
  final String scope;
  final String message;
  final Map<String, Object?>? data;

  /// Multi-line extra context (exception fields, stack). Kept out of
  /// [format] so that stays one greppable line.
  final String? detail;

  /// One line, stable and greppable — the format a bug report gets pasted as.
  String format() {
    final t = at.toUtc().toIso8601String().substring(11, 23);
    final tail = (data == null || data!.isEmpty)
        ? ''
        : ' ${data!.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    return '$t ${level.label.padRight(5)} [$scope] $message$tail';
  }

  /// [format], then each [detail] line indented by four spaces.
  String formatFull() {
    final d = detail;
    if (d == null || d.isEmpty) return format();
    return '${format()}\n${d.split('\n').map((l) => '    $l').join('\n')}';
  }
}

class Logger {
  Logger._();

  static final Logger instance = Logger._();

  /// Entries kept in memory. Enough to cover a full 64-block dump with room to
  /// spare, bounded so a long session cannot grow without limit.
  static const int capacity = 2000;

  final List<LogEntry> _entries = [];
  int _seq = 0;

  /// Raise to `LogLevel.info` to quieten frame-level tracing.
  LogLevel minLevel = LogLevel.debug;

  /// Mirror to the developer console. On by default: the whole point is that a
  /// hardware session shows its work.
  bool mirrorToConsole = true;

  List<LogEntry> snapshot() => List.unmodifiable(_entries);

  void clear() => _entries.clear();

  /// Longest [LogEntry.detail] kept; longer text is cut and marked.
  static const int maxDetailChars = 8192;

  final List<void Function(LogEntry)> _listeners = [];

  /// Called for every recorded entry (after the level filter).
  void addListener(void Function(LogEntry) l) => _listeners.add(l);

  void removeListener(void Function(LogEntry) l) => _listeners.remove(l);

  void debug(String scope, String message,
          [Map<String, Object?>? data, String? detail]) =>
      _add(LogLevel.debug, scope, message, data, detail);

  void info(String scope, String message,
          [Map<String, Object?>? data, String? detail]) =>
      _add(LogLevel.info, scope, message, data, detail);

  void warn(String scope, String message,
          [Map<String, Object?>? data, String? detail]) =>
      _add(LogLevel.warn, scope, message, data, detail);

  void error(String scope, String message,
          [Map<String, Object?>? data, String? detail]) =>
      _add(LogLevel.error, scope, message, data, detail);

  /// Logs at `error` with the exception (and stack) as [LogEntry.detail].
  void report(String scope, String message, Object error,
          [StackTrace? stack, Map<String, Object?>? data]) =>
      _add(LogLevel.error, scope, message, data, errorDetail(error, stack));

  void _add(
    LogLevel level,
    String scope,
    String message,
    Map<String, Object?>? data,
    String? detail,
  ) {
    if (level.rank < minLevel.rank) return;

    final entry = LogEntry(
      seq: _seq++,
      at: DateTime.now(),
      level: level,
      scope: scope,
      message: message,
      data: data,
      detail: detail,
    );

    _entries.add(entry);
    if (_entries.length > capacity) _entries.removeAt(0);

    if (mirrorToConsole) {
      final line = entry.formatFull();
      // BOTH destinations, because they are genuinely different streams and
      // the first hardware session proved it: developer.log() reaches only the
      // VM service (DevTools' Logging view) and appears in NEITHER `flutter
      // run` stdout nor `adb logcat`. debugPrint is what actually reaches both.
      //
      // Prefixed rather than tagged, since debugPrint has no tag parameter —
      // `grep nfar:` is the filter.
      debugPrint('nfar: $line');
      developer.log(line, name: 'nfar.$scope');
    }

    for (final l in List.of(_listeners)) {
      try {
        l(entry);
      } catch (_) {
        // A faulty listener must never break logging.
      }
    }
  }
}

/// Exception text for [LogEntry.detail]: PlatformException fields on separate
/// lines, otherwise `toString()`, then the stack; capped to
/// [Logger.maxDetailChars].
String errorDetail(Object error, StackTrace? stack) {
  final b = StringBuffer();
  if (error is PlatformException) {
    b
      ..writeln('code: ${error.code}')
      ..writeln('message: ${error.message}')
      ..write('details: ${error.details}');
  } else {
    b.write(error.toString());
  }
  if (stack != null) b.write('\n$stack');
  final s = b.toString();
  if (s.length <= Logger.maxDetailChars) return s;
  return '${s.substring(0, Logger.maxDetailChars)}… [truncated]';
}

/// Uppercase, space-separated hex — the form that can be compared against a
/// protocol document or pasted into a bug report without re-formatting.
String hexDump(Uint8List bytes, {int max = 64}) {
  final shown = bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
  final body =
      shown.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
  return bytes.length <= max ? body : '$body … (${bytes.length} B)';
}

/// The app-wide logger.
final log = Logger.instance;
