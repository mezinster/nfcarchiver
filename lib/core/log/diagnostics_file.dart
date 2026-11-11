import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'logger.dart';

/// Rotating on-device sink for `info`/`warn`/`error` log entries.
///
/// All I/O goes through one [Future] chain, so writes never interleave, and
/// every I/O call is guarded: a failure sets [degraded] and the sink becomes
/// a no-op. Logging must never be what breaks the app.
class DiagnosticsFile {
  DiagnosticsFile({
    required this.dir,
    this.maxBytes = 512 * 1024,
    this.flushEvery = const Duration(seconds: 2),
  });

  static const fileName = 'diagnostics.log';
  static const previousFileName = 'diagnostics.1.log';

  final Directory dir;
  final int maxBytes;
  final Duration flushEvery;

  final List<String> _buffer = [];
  Timer? _timer;
  Future<void> _chain = Future.value();
  bool _degraded = false;

  /// True after any I/O failure; the sink then ignores everything.
  bool get degraded => _degraded;

  File get _current => File('${dir.path}/$fileName');
  File get _previous => File('${dir.path}/$previousFileName');

  void add(LogEntry e) {
    if (_degraded || e.level.rank < LogLevel.info.rank) return;
    _buffer.add(e.formatFull());
    if (e.level.rank >= LogLevel.warn.rank) {
      unawaited(flush());
    } else {
      _arm();
    }
  }

  /// A raw line (e.g. the session header), written with the next flush.
  void writeLine(String line) {
    if (_degraded) return;
    _buffer.add(line);
    _arm();
  }

  void _arm() => _timer ??= Timer(flushEvery, () => unawaited(flush()));

  Future<void> _enqueue(Future<void> Function() job) {
    _chain = _chain.then((_) async {
      try {
        await job();
      } catch (_) {
        _degraded = true;
      }
    });
    return _chain;
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_degraded || _buffer.isEmpty) return _chain;
    final lines = List<String>.of(_buffer);
    _buffer.clear();
    return _enqueue(() => _append(lines));
  }

  Future<void> _append(List<String> lines) async {
    if (_degraded) return;
    await dir.create(recursive: true);
    var size = await _current.exists() ? await _current.length() : 0;
    final chunk = StringBuffer();
    var chunkBytes = 0;

    Future<void> writeChunk() async {
      if (chunkBytes == 0) return;
      await _current.writeAsString(chunk.toString(),
          mode: FileMode.append, flush: true);
      size += chunkBytes;
      chunk.clear();
      chunkBytes = 0;
    }

    for (final line in lines) {
      final text = '$line\n';
      final n = utf8.encode(text).length;
      if (size + chunkBytes + n >= maxBytes && size + chunkBytes > 0) {
        await writeChunk();
        if (await _current.exists()) {
          await _current.rename(_previous.path); // replaces any existing one
        }
        size = 0;
      }
      chunk.write(text);
      chunkBytes += n;
    }
    await writeChunk();
  }

  /// Previous file, then current, after a flush. Empty when degraded.
  Future<String> readAll() async {
    await flush();
    var out = '';
    await _enqueue(() async {
      if (_degraded) return;
      final b = StringBuffer();
      if (await _previous.exists()) b.write(await _previous.readAsString());
      if (await _current.exists()) b.write(await _current.readAsString());
      out = b.toString();
    });
    return out;
  }

  /// Drops the pending buffer and deletes both files.
  Future<void> clear() {
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
    return _enqueue(() async {
      if (await _current.exists()) await _current.delete();
      if (await _previous.exists()) await _previous.delete();
    });
  }

  /// Writes `nfc-archiver-log-<yyyyMMdd-HHmmss>.txt` (local time of [now]) =
  /// [header] + newline + [readAll] into [tmp].
  Future<File> exportTo(Directory tmp,
      {required DateTime now, required String header}) async {
    final content = await readAll();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    final stamp = '${p(now.year, 4)}${p(now.month)}${p(now.day)}-'
        '${p(now.hour)}${p(now.minute)}${p(now.second)}';
    final file = File('${tmp.path}/nfc-archiver-log-$stamp.txt');
    await file.writeAsString('$header\n$content');
    return file;
  }
}
