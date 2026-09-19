/// The two kinds of NFC session the app arms.
enum SessionKind { read, write }

/// Decides whether the tag connection Android is still holding should be
/// dropped before a new session is armed.
///
/// While a card stays in the field NfcService keeps it "connected" and answers
/// a fresh `enableReaderMode` with `applyRouting: Not updating discovery
/// parameters, tag connected`, so the new session is never told about the
/// card. Dropping the connection (`disableReaderMode`) forces a rediscovery.
///
/// That is wanted whenever the user starts something new with the card already
/// in place — and unwanted in exactly one situation: re-arming the same kind
/// of session straight after it succeeded, where the card still in the field
/// is one we are *done* with. There the carry-over is a feature:
///
/// * read → read: the scan screen re-arms after every read; releasing re-reads
///   the same card in a loop.
/// * write → write: the next chunk would be written over the card that just
///   received the previous one if the user has not lifted it yet.
///
/// The protection is spent by a single arm, so a retry after an error sees the
/// card that is still in place.
class StaleTagPolicy {
  SessionKind? _justSucceeded;

  /// Call when a session of [kind] finished successfully on a tag.
  void succeeded(SessionKind kind) => _justSucceeded = kind;

  /// Whether to drop the stale connection before arming a [kind] session.
  bool shouldReleaseBefore(SessionKind kind) {
    final release = _justSucceeded != kind;
    _justSucceeded = null;
    return release;
  }
}
