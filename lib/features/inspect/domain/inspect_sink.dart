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
