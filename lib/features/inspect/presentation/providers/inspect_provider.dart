import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/chameleon/cancellation_token.dart';
import '../../../../core/chameleon/chameleon_device.dart';
import '../../domain/inspect_sink.dart';
import '../../domain/run_inspection.dart';

class InspectState {
  const InspectState({
    this.rows = const [],
    this.identity,
    this.nfar,
    this.progress,
    this.report,
    this.status,
    this.isRunning = false,
  });

  final List<String> rows;
  final String? identity;
  final String? nfar;
  final String? progress;
  final String? report;
  final String? status;
  final bool isRunning;

  InspectState copyWith({
    List<String>? rows,
    String? identity,
    String? nfar,
    String? progress,
    String? report,
    String? status,
    bool? isRunning,
  }) =>
      InspectState(
        rows: rows ?? this.rows,
        identity: identity ?? this.identity,
        nfar: nfar ?? this.nfar,
        progress: progress ?? this.progress,
        report: report ?? this.report,
        status: status ?? this.status,
        isRunning: isRunning ?? this.isRunning,
      );
}

/// Drives an inspection and exposes it as Riverpod state.
///
/// **Superseded runs may only touch state they still own.** When a second
/// inspection starts while the first is still draining, the first one's
/// already-scheduled callbacks must not scribble into the second one's state.
/// The web app hit exactly this and fixed it in commit `67c4683`.
///
/// The guard therefore lives in a per-run sink that closes over *its own*
/// token — not in a check against a field, which a stale run would read as
/// current and sail straight through. A guard placed only at the entry point
/// cannot help either: by then the damaging callbacks are already queued.
class InspectNotifier extends StateNotifier<InspectState> {
  InspectNotifier() : super(const InspectState());

  CancellationToken? _token;

  /// True only for the run that currently owns the state.
  bool _owns(CancellationToken t) => identical(t, _token);

  Future<void> start(ChameleonDevice dev) async {
    _token?.cancel();
    final token = CancellationToken();
    _token = token;

    state = const InspectState(isRunning: true);
    await runInspection(dev, _OwnedSink(this, token), token: token);

    // Only the owning run may declare the inspection finished; a stale run
    // reaching here must leave the newer one's isRunning alone.
    if (_owns(token)) state = state.copyWith(isRunning: false);
  }

  void cancel() {
    _token?.cancel();
    if (state.isRunning) state = state.copyWith(isRunning: false);
  }

  // Mutations, applied only via _OwnedSink so ownership is always checked.
  void _setIdentity(String t) => state = state.copyWith(identity: t);
  void _setNfar(String t) => state = state.copyWith(nfar: t);
  void _setProgress(String t) => state = state.copyWith(progress: t);
  void _setReport(String t) => state = state.copyWith(report: t);
  void _setStatus(String t) => state = state.copyWith(status: t);
  void _appendRow(String line) =>
      state = state.copyWith(rows: [...state.rows, line]);
}

/// A sink bound to one run. Every method drops its call once superseded.
class _OwnedSink implements InspectSink {
  _OwnedSink(this._n, this._token);

  final InspectNotifier _n;
  final CancellationToken _token;

  bool get _live => _n._owns(_token);

  @override
  void setIdentity(String text) {
    if (_live) _n._setIdentity(text);
  }

  @override
  void setNfar(String text) {
    if (_live) _n._setNfar(text);
  }

  @override
  void appendRow(String line) {
    if (_live) _n._appendRow(line);
  }

  @override
  void setProgress(String text) {
    if (_live) _n._setProgress(text);
  }

  @override
  void setReport(String text) {
    if (_live) _n._setReport(text);
  }

  @override
  void setStatus(String text) {
    if (_live) _n._setStatus(text);
  }
}

final inspectProvider =
    StateNotifierProvider<InspectNotifier, InspectState>((ref) {
  return InspectNotifier();
});
