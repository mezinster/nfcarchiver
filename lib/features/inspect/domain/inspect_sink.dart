/// How [runInspection] reports progress.
///
/// Six methods, mirroring the web app's `InspectIO`, so the orchestration is
/// testable with no widget and no DOM stub.
///
/// Callbacks rather than a `Stream<InspectEvent>` on purpose. A stream is the
/// more idiomatic Dart shape, but it would diverge both from the TypeScript
/// this is ported from and from this app's own convention — every NFC session
/// is already driven through `onTagDiscovered` / `onChunkRead` / `onError`.
/// `InspectNotifier` implements this and exposes Riverpod state, so the
/// idiomatic surface exists one layer up, where Flutter actually wants it.
abstract class InspectSink {
  void setIdentity(String text);
  void setNfar(String text);
  void appendRow(String line);
  void setProgress(String text);
  void setReport(String text);
  void setStatus(String text);
}

/// The chrome strings [runInspection] emits.
///
/// Passed in rather than looked up, so the domain layer stays free of Flutter
/// and of AppLocalizations while the status line is still translated. The
/// REPORT body deliberately stays English — it is diagnostic output meant to
/// be pasted into a bug report, where a translated hex dump helps nobody.
class InspectStrings {
  const InspectStrings({
    required this.holdStill,
    required this.done,
    required this.stopped,
    required this.cardLost,
    required this.reading,
    required this.read,
  });

  final String holdStill;
  final String done;
  final String stopped;
  final String cardLost;
  final String Function(int done, int total) reading;
  final String Function(int done, int total) read;

  /// English fallback, for tests and for any call site without a context.
  static InspectStrings english() => InspectStrings(
        holdStill: 'Hold the card still on the reader…',
        done: 'Inspection complete.',
        stopped: 'Stopped.',
        cardLost: 'Card left the field — partial dump.',
        reading: (d, t) => 'Reading $d of $t…',
        read: (d, t) => 'Read $d of $t',
      );
}
