/// Severity of a parsed log line, as far as colouring and filtering care.
enum LogLineLevel { none, debug, info, warn, error }

/// One physical line of the diagnostics log. Detail lines inherit the level
/// of the entry above them, so filtering keeps an error with its stack.
class LogLine {
  const LogLine(this.text, this.level,
      {this.isDetail = false, this.isHeader = false});

  final String text;
  final LogLineLevel level;
  final bool isDetail;
  final bool isHeader;

  bool get isProblem =>
      level == LogLineLevel.warn || level == LogLineLevel.error;
}

final _entryLine =
    RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} (DEBUG|INFO |WARN |ERROR)');

/// Splits log [text] into [LogLine]s: entry lines (`HH:mm:ss.SSS LEVEL ...`),
/// indented detail lines, and `===` session headers.
List<LogLine> parseLogLines(String text) {
  final out = <LogLine>[];
  var current = LogLineLevel.none;
  for (final raw in text.split('\n')) {
    if (raw.isEmpty) continue;
    if (raw.startsWith('===')) {
      current = LogLineLevel.none;
      out.add(LogLine(raw, LogLineLevel.none, isHeader: true));
      continue;
    }
    final m = _entryLine.firstMatch(raw);
    if (m != null) {
      current = switch (m.group(1)!.trim()) {
        'DEBUG' => LogLineLevel.debug,
        'INFO' => LogLineLevel.info,
        'WARN' => LogLineLevel.warn,
        _ => LogLineLevel.error,
      };
      out.add(LogLine(raw, current));
    } else {
      out.add(LogLine(raw, current, isDetail: true));
    }
  }
  return out;
}

/// Lines for the "Warnings & errors" filter: problem entries with their
/// detail lines, plus session headers.
List<LogLine> onlyProblems(List<LogLine> lines) =>
    lines.where((l) => l.isHeader || l.isProblem).toList();
