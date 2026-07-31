/// Cooperative cancellation for long-running card operations.
///
/// Dart has no `AbortSignal`, and this is the minimum that replaces one — kept
/// deliberately tiny rather than pulling in a dependency for two fields.
///
/// It serves a second purpose that matters more than cancellation itself: it is
/// the **ownership marker** for superseded runs. When a second inspection starts
/// while the first is still draining, the first one's in-flight callbacks must
/// not scribble into the second one's state. Callers therefore capture the token
/// belonging to *their* run and check it inside every callback — not merely once
/// before starting, because the damage is done by callbacks already scheduled.
///
/// The same rule appears three times in the web app for the same reason:
/// `readerEpoch` in `device.ts`, the ownership guard in `browser-ndef-io.ts`,
/// and `ReaderLock.release` being owner-checked. A superseded operation may only
/// touch state it still owns.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
