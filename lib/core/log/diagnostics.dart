import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics_file.dart';
import 'logger.dart';

/// The persistent log sink. Overridden in `main()`; `null` means unavailable
/// (tests, or the support directory could not be resolved).
final diagnosticsFileProvider = Provider<DiagnosticsFile?>((ref) => null);

bool _inHook = false;

// Held so the lifecycle observer is not garbage-collected.
// ignore: unused_element
AppLifecycleListener? _lifecycle;

/// Routes uncaught Flutter and async errors into [logger]. A guard drops
/// re-entrant calls and swallows failures: the error hook must never throw.
void installErrorHooks(Logger logger) {
  FlutterError.onError = (details) {
    _guarded(() => logger.report(
        'flutter', 'Uncaught Flutter error', details.exception, details.stack));
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _guarded(
        () => logger.report('platform', 'Uncaught async error', error, stack));
    return true;
  };
}

void _guarded(void Function() body) {
  if (_inHook) return;
  _inHook = true;
  try {
    body();
  } catch (_) {
    // Logging must never be what breaks the app.
  } finally {
    _inHook = false;
  }
}

String sessionHeader({
  required String version,
  required String build,
  required String os,
  required String locale,
  required DateTime at,
  String label = 'session start',
}) =>
    '=== NFC Archiver $version ($build) · $os · $locale · '
    '$label ${at.toUtc().toIso8601String()} ===';

/// Starts persisting [logger]. Returns `null` on any failure, leaving the
/// logger memory-only. [locale] is the app's language tag (system locale when
/// omitted); the resolvers are injectable for tests.
Future<DiagnosticsFile?> startDiagnostics(
  Logger logger, {
  String? locale,
  Future<Directory> Function()? supportDir,
  Future<PackageInfo> Function()? packageInfo,
}) async {
  try {
    final support = await (supportDir ?? getApplicationSupportDirectory)();
    final file = DiagnosticsFile(dir: Directory('${support.path}/logs'));
    final info = await (packageInfo ?? PackageInfo.fromPlatform)();
    file.writeLine(sessionHeader(
      version: info.version,
      build: info.buildNumber,
      os: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      locale: locale ?? PlatformDispatcher.instance.locale.toLanguageTag(),
      at: DateTime.now(),
    ));
    _lifecycle = AppLifecycleListener(
      onPause: () => unawaited(file.flush()),
      onDetach: () => unawaited(file.flush()),
    );
    // Last, so a failed start leaves no listener attached.
    logger.addListener(file.add);
    return file;
  } catch (_) {
    return null;
  }
}
