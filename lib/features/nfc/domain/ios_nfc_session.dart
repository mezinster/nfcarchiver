import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import '../../../core/log/logger.dart';
import 'card_reader.dart';

/// Core NFC sessions — restore scans and archive writes alike — one system
/// sheet per tag. One instance serves both, because nfc_manager holds a single
/// session at a time.
///
/// The restore screen re-arms after every tag, which on Android is free. On
/// iOS every session is a system sheet with rules of its own, and each rule
/// below answers something the first Core NFC builds did on a real iPhone:
///
/// * **Each tag ends its sheet.** iOS gives feedback — checkmark or cross, and
///   a haptic — only when a session ENDS; the app's own vibration does not get
///   through while a sheet is up. A build that kept one sheet open across tags
///   was silent. So a read ends with [end]: success for a new chunk, a problem
///   for a duplicate or an unreadable tag.
/// * **The next sheet waits for the last to close.** Begun ~0.2 s after an end,
///   a new session was cancelled 2.5 s later, when the old sheet finished its
///   dismiss animation; begun straight after iOS ended a session, it was
///   refused with "System resource unavailable". [beforeBegin] waits out
///   [sheetCooldown] — and since iOS still refused some begins at 3.0 s
///   ("Session invalidated unexpectedly", 60 ms in) yet took them 3 s later, a
///   refusal right at the begin is retried every [refusalRetryGap] instead of
///   reported ([refusedAtBegin]). The sheet reappears as soon as iOS allows.
/// * **Released when iOS ends it.** nfc_manager's `didInvalidateWithError`
///   never clears its handle — only `stopSession` does — so without a release
///   every later session fails with `session_already_exists`.
/// * **A tag resting on the phone is read once.** It is found again the moment
///   the next sheet opens; read in a loop, it was a duplicate every few
///   seconds. A tag seen again within [repeatWindow] of its last sighting is a
///   repeat: the sheet stays up ([keepPolling]) waiting for a real tap.
///
/// Android is untouched: nothing ends, waits, repeats or releases.
class IosNfcSession {
  IosNfcSession({
    required Future<void> Function() restartPolling,
    required Future<void> Function({String? alertMessage, String? errorMessage})
        invalidate,
    Future<void> Function(Duration)? wait,
    DateTime Function()? clock,
  })  : _restartPolling = restartPolling,
        _invalidate = invalidate,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        _clock = clock ?? DateTime.now;

  /// Minimum gap between a session ending and the next beginning. The old
  /// sheet finished dismissing ~2.7 s after its end on an iPhone 13 Pro.
  static const sheetCooldown = Duration(milliseconds: 3000);

  /// Pause before polling again after a repeat, so a tag left on the phone is
  /// not re-read at the radio's ~2 Hz until iOS kills the session.
  static const repeatPause = Duration(milliseconds: 1500);

  /// A session iOS terminates within this long of its begin was refused, not
  /// lost: it never got as far as polling.
  static const refusalWindow = Duration(milliseconds: 500);

  /// Retry gap after such a refusal.
  static const refusalRetryGap = Duration(milliseconds: 500);

  /// Refusals retried in a row before one is reported as an error after all.
  static const maxRefusalRetries = 10;

  /// A tag seen again within this long of its last sighting never left. Must
  /// exceed [sheetCooldown] plus a discovery, since the next sheet finds a
  /// resting tag at once.
  static const repeatWindow = Duration(milliseconds: 5000);

  final Future<void> Function() _restartPolling;
  final Future<void> Function({String? alertMessage, String? errorMessage})
      _invalidate;
  final Future<void> Function(Duration) _wait;
  final DateTime Function() _clock;

  bool _live = false;
  DateTime? _begunAt;
  DateTime? _nextBeginAt;
  int _refusalRetries = 0;
  String? _lastTagId;
  DateTime? _lastTagSeen;

  bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

  /// Await before beginning a native session.
  Future<void> beforeBegin() async {
    if (!_isIos) return;
    // Nothing ended the last tag's sheet; the plugin would refuse a new one.
    if (_live) await end();
    if (_nextBeginAt == null) return;
    final remaining = _nextBeginAt!.difference(_clock());
    if (remaining > Duration.zero) await _wait(remaining);
  }

  /// Call once a native session was begun.
  void began() {
    if (!_isIos) return;
    _live = true;
    _begunAt = _clock();
  }

  /// Whether iOS terminating the session with [code] means it refused the
  /// begin (not ready yet, retry shortly) rather than lost a working session.
  bool refusedAtBegin(NfcReaderErrorCodeIos code) =>
      _isIos &&
      code ==
          NfcReaderErrorCodeIos
              .readerSessionInvalidationErrorSessionTerminatedUnexpectedly &&
      _begunAt != null &&
      _clock().difference(_begunAt!) < refusalWindow &&
      _refusalRetries < maxRefusalRetries;

  /// After [refusedAtBegin]: release the refused session; the next begin
  /// waits only [refusalRetryGap].
  Future<void> retryAfterRefusal() async {
    if (!_isIos) return;
    _refusalRetries++;
    await _release();
    _nextBeginAt = _clock().add(refusalRetryGap);
  }

  /// End the open sheet, showing [message] — as a failure if [problem].
  Future<void> end({String? message, bool problem = false}) async {
    if (!_isIos || !_live) return;
    _live = false;
    _nextBeginAt = _clock().add(sheetCooldown);
    _refusalRetries = 0;
    try {
      await _invalidate(
        alertMessage: problem ? null : message,
        errorMessage: problem ? message : null,
      );
    } catch (e) {
      Logger.instance.debug('nfc', 'ios session end failed', {'error': e});
    }
  }

  /// Whether [tagId] is the tag that was just handled and never left. Records
  /// the sighting either way.
  bool isRepeat(String tagId) {
    if (!_isIos || tagId.isEmpty) return false;
    final now = _clock();
    final repeat = tagId == _lastTagId &&
        _lastTagSeen != null &&
        now.difference(_lastTagSeen!) < repeatWindow;
    _lastTagId = tagId;
    _lastTagSeen = now;
    return repeat;
  }

  /// After a repeat: keep the sheet up and poll again, unhurried.
  Future<void> keepPolling() async {
    if (!_isIos) return;
    await _wait(repeatPause);
    // The scan may have been stopped, or the sheet ended, during the pause.
    if (!_live) return;
    try {
      await _restartPolling();
    } catch (e) {
      Logger.instance.debug('nfc', 'ios restart polling failed', {'error': e});
      await invalidatedBySystem();
    }
  }

  /// Call when iOS invalidated the session, before reporting it.
  Future<void> invalidatedBySystem() async {
    if (!_isIos) return;
    await _release();
    _nextBeginAt = _clock().add(sheetCooldown);
  }

  Future<void> _release() async {
    _live = false;
    try {
      await _invalidate();
    } catch (e) {
      // Already gone is fine; the caller is about to report what matters.
      Logger.instance.debug('nfc', 'ios session release failed', {'error': e});
    }
  }

  /// Call when the app stopped the session itself.
  void stopped() {
    if (!_isIos) return;
    if (_live) _nextBeginAt = _clock().add(sheetCooldown);
    _live = false;
  }
}

/// Whether an iOS session error ends the scan rather than being retried.
///
/// Cancel is the user saying stop; the 60 s timeout means nobody is tapping.
/// Re-opening the sheet after either is what made Cancel impossible.
ScanStop? scanStopFor(NfcReaderErrorCodeIos code) => switch (code) {
      NfcReaderErrorCodeIos.readerSessionInvalidationErrorUserCanceled =>
        ScanStop.cancelled,
      NfcReaderErrorCodeIos.readerSessionInvalidationErrorSessionTimeout =>
        ScanStop.timedOut,
      _ => null,
    };
