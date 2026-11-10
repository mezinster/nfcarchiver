import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/log/diagnostics.dart';
import '../../../core/log/logger.dart';
import '../../../core/services/file_actions_service.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import '../log_lines.dart';

/// Where the "Details" buttons on NFC errors lead.
const diagnosticsRoute = '/diagnostics';

/// Where the exported log is written before sharing. Overridable in tests.
final diagnosticsTempDirProvider =
    Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// The on-device diagnostics log: raw monospace lines, newest at the bottom.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  List<LogLine>? _lines;
  String _text = '';
  bool _problemsOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _readText() async {
    final file = ref.read(diagnosticsFileProvider);
    // A degraded sink reads back as '' — the in-memory log is all there is.
    if (file != null && !file.degraded) return file.readAll();
    return log
        .snapshot()
        .where((e) => e.level.rank >= LogLevel.info.rank)
        .map((e) => e.formatFull())
        .join('\n');
  }

  Future<void> _load() async {
    final text = await _readText();
    if (!mounted) return;
    setState(() {
      _text = text;
      _lines = parseLogLines(text);
    });
  }

  Future<String> _header(String locale, DateTime at) async {
    final info = await PackageInfo.fromPlatform();
    return sessionHeader(
      version: info.version,
      build: info.buildNumber,
      os: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      locale: locale,
      at: at,
      label: 'exported',
    );
  }

  Future<void> _share() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    try {
      final now = DateTime.now();
      final header = await _header(locale, now);
      final tmp = await ref.read(diagnosticsTempDirProvider)();
      final file = ref.read(diagnosticsFileProvider);
      final String path;
      if (file != null && !file.degraded) {
        path = (await file.exportTo(tmp, now: now, header: header)).path;
      } else {
        final f = File('${tmp.path}/nfc-archiver-log-${_stamp(now)}.txt');
        await f.writeAsString('$header\n${await _readText()}');
        path = f.path;
      }
      await ref.read(fileActionsProvider).shareFile(path);
    } catch (e, s) {
      log.report('diagnostics', 'Sharing the log failed', e, s);
      messenger.showSnackBar(SnackBar(content: Text(l10n.somethingWentWrong)));
    }
  }

  String _stamp(DateTime n) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.year, 4)}${p(n.month)}${p(n.day)}-'
        '${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  Future<void> _clear() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.diagnosticsClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.diagnosticsClearAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(diagnosticsFileProvider)?.clear();
    log.clear();
    await _load();
  }

  Color? _color(LogLine l, ColorScheme cs) => switch (l.level) {
        LogLineLevel.error => cs.error,
        LogLineLevel.warn => cs.tertiary,
        _ => l.isHeader ? cs.primary : null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final all = _lines;
    final shown = all == null
        ? const <LogLine>[]
        : (_problemsOnly ? onlyProblems(all) : all);
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace', fontSize: 12);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.diagnosticsLog),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: l10n.diagnosticsShare,
            onPressed: _share,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.diagnosticsClear,
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilterChip(
                  label: Text(l10n.diagnosticsFilterAll),
                  selected: !_problemsOnly,
                  onSelected: (_) => setState(() => _problemsOnly = false),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(l10n.diagnosticsFilterProblems),
                  selected: _problemsOnly,
                  onSelected: (_) => setState(() => _problemsOnly = true),
                ),
              ],
            ),
          ),
          Expanded(
            child: all == null
                ? const SizedBox.shrink()
                : _text.trim().isEmpty
                    ? Center(child: Text(l10n.diagnosticsEmpty))
                    // reverse: the list starts at its end, so it opens
                    // scrolled to the newest line without a jump.
                    : SelectionArea(
                        child: ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          itemCount: shown.length,
                          itemBuilder: (_, i) {
                            final line = shown[shown.length - 1 - i];
                            return Text(
                              line.text,
                              style: style?.copyWith(color: _color(line, cs)),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
