import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/ios_read_session.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

/// Core NFC read sessions during a scan: one sheet per tag.
///
/// Each rule answers something the first Core NFC builds did on a real iPhone:
/// a second session refused while one was open; a session begun 0.2 s after
/// ending the last cancelled 2.5 s later by the old sheet's dismiss; a tag
/// resting on the phone re-read until iOS killed the session; "System resource
/// unavailable" on an immediate restart; and no haptic at all while a sheet
/// stayed open — iOS buzzes only when a session ends.
void main() {
  late List<String> calls;
  late List<Duration> waits;
  late DateTime now;
  late IosReadSession session;

  IosReadSession make({
    Future<void> Function()? restartPolling,
    Future<void> Function({String? alertMessage, String? errorMessage})?
        invalidate,
  }) =>
      IosReadSession(
        restartPolling:
            restartPolling ?? () async => calls.add('restartPolling'),
        invalidate: invalidate ??
            ({alertMessage, errorMessage}) async => calls.add(
                'invalidate alert=$alertMessage error=$errorMessage'),
        wait: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        clock: () => now,
      );

  setUp(() {
    calls = [];
    waits = [];
    now = DateTime(2026, 11, 6, 12);
    session = make();
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    group('ending the sheet after a tag', () {
      // iOS's checkmark and success haptic come with a plain invalidate.
      test('a good read ends with the message as a success', () async {
        session.began();
        await session.end(message: 'Chunk 3 of 12');
        expect(calls, ['invalidate alert=Chunk 3 of 12 error=null']);
      });

      // A failure-style end gives a different sheet and haptic.
      test('a problem ends with the message as an error', () async {
        session.began();
        await session.end(message: 'Chunk 3 of 12 already scanned', problem: true);
        expect(calls, ['invalidate alert=null error=Chunk 3 of 12 already scanned']);
      });

      test('ending twice invalidates once', () async {
        session.began();
        await session.end(message: 'a');
        await session.end(message: 'b');
        expect(calls, hasLength(1));
      });

      test('there is nothing to end before a session began', () async {
        await session.end(message: 'a');
        expect(calls, isEmpty);
      });

      test('a failing invalidate is swallowed', () async {
        final failing = make(
          invalidate: ({alertMessage, errorMessage}) async =>
              throw Exception('no session'),
        )..began();
        await expectLater(failing.end(message: 'a'), completes);
      });
    });

    group('beginning the next sheet', () {
      test('the very first begin does not wait', () async {
        await session.beforeBegin();
        expect(waits, isEmpty);
        expect(calls, isEmpty);
      });

      // Begun sooner, the new sheet was cancelled by the old one's dismiss.
      test('waits until the last sheet has finished closing', () async {
        session.began();
        await session.end(message: 'Chunk 1 of 3');
        now = now.add(const Duration(milliseconds: 400));
        await session.beforeBegin();
        expect(waits, [IosReadSession.sheetCooldown - const Duration(milliseconds: 400)]);
      });

      test('a begin after the cool-down does not wait', () async {
        session.began();
        await session.end(message: 'Chunk 1 of 3');
        now = now.add(IosReadSession.sheetCooldown);
        await session.beforeBegin();
        expect(waits, isEmpty);
      });

      // Safety net: whatever left a session open (nobody ended the tag), the
      // plugin would refuse the new one with session_already_exists.
      test('a session still open is ended first', () async {
        session.began();
        await session.beforeBegin();
        expect(calls, ['invalidate alert=null error=null']);
        expect(waits, [IosReadSession.sheetCooldown]);
      });
    });

    // Measured on an iPhone 13 Pro: begun 3.0 s after the last sheet ended,
    // a session was refused 60 ms in ("Session invalidated unexpectedly");
    // 3 s later it worked. Waiting a full cool-down again after the refusal
    // doubled the gap between sheets and showed the user an error each time.
    group('a begin iOS refuses at once', () {
      const terminated = NfcReaderErrorCodeIos
          .readerSessionInvalidationErrorSessionTerminatedUnexpectedly;

      test('is "not ready yet" when it comes right after the begin', () {
        session.began();
        now = now.add(const Duration(milliseconds: 60));
        expect(session.refusedAtBegin(terminated), isTrue);
      });

      test('is a real error once the session has been up a while', () {
        session.began();
        now = now.add(IosReadSession.refusalWindow);
        expect(session.refusedAtBegin(terminated), isFalse);
      });

      test('is only ever the unexpected-termination error', () {
        session.began();
        expect(
          session.refusedAtBegin(NfcReaderErrorCodeIos
              .readerSessionInvalidationErrorUserCanceled),
          isFalse,
        );
      });

      test('is retried after a short gap, not a whole cool-down', () async {
        session.began();
        expect(session.refusedAtBegin(terminated), isTrue);
        await session.retryAfterRefusal();
        await session.beforeBegin();
        expect(waits, [IosReadSession.refusalRetryGap]);
      });

      test('is released before the retry', () async {
        session.began();
        session.refusedAtBegin(terminated);
        await session.retryAfterRefusal();
        expect(calls, ['invalidate alert=null error=null']);
      });

      // Something other than "not ready" must surface eventually.
      test('stops being retried after too many in a row', () async {
        for (var i = 0; i < IosReadSession.maxRefusalRetries; i++) {
          session.began();
          expect(session.refusedAtBegin(terminated), isTrue, reason: 'try $i');
          await session.retryAfterRefusal();
        }
        session.began();
        expect(session.refusedAtBegin(terminated), isFalse);
      });

      test('a handled tag resets the retry budget', () async {
        for (var i = 0; i < IosReadSession.maxRefusalRetries; i++) {
          session.began();
          session.refusedAtBegin(terminated);
          await session.retryAfterRefusal();
        }
        session.began();
        await session.end(message: 'Chunk 1 of 3');
        session.began();
        expect(session.refusedAtBegin(terminated), isTrue);
      });
    });

    group('when iOS ends the session', () {
      // nfc_manager only drops its handle on stopSession, never when iOS ends
      // the session — without this every later start is session_already_exists.
      test('it is released', () async {
        session.began();
        await session.invalidatedBySystem();
        expect(calls, ['invalidate alert=null error=null']);
      });

      test('the next begin waits out the cool-down', () async {
        session.began();
        await session.invalidatedBySystem();
        await session.beforeBegin();
        expect(waits, [IosReadSession.sheetCooldown]);
      });

      test('a failing release is swallowed', () async {
        final failing = make(
          invalidate: ({alertMessage, errorMessage}) async =>
              throw Exception('no session'),
        )..began();
        await expectLater(failing.invalidatedBySystem(), completes);
      });
    });

    group('a tag resting on the phone', () {
      test('is new the first time', () {
        expect(session.isRepeat('04A1B2'), isFalse);
      });

      // It is found again at once when the next sheet opens, ~3.5 s after the
      // last sighting — the window has to cover the sheet's cool-down.
      test('is a repeat when the next sheet finds it again', () {
        session.isRepeat('04A1B2');
        now = now.add(IosReadSession.sheetCooldown + const Duration(milliseconds: 800));
        expect(session.isRepeat('04A1B2'), isTrue);
      });

      test('stays a repeat while it keeps being rediscovered', () {
        session.isRepeat('04A1B2');
        for (var i = 0; i < 5; i++) {
          now = now.add(IosReadSession.repeatPause + const Duration(milliseconds: 600));
          expect(session.isRepeat('04A1B2'), isTrue, reason: 'rediscovery $i');
        }
      });

      test('is new again once it has been away', () {
        session.isRepeat('04A1B2');
        now = now.add(IosReadSession.repeatWindow + const Duration(milliseconds: 1));
        expect(session.isRepeat('04A1B2'), isFalse);
      });

      test('a different tag is never a repeat', () {
        session.isRepeat('04A1B2');
        expect(session.isRepeat('04C3D4'), isFalse);
      });

      // No identifier, no way to tell: read it rather than drop a chunk.
      test('a tag without an identifier is never a repeat', () {
        session.isRepeat('');
        expect(session.isRepeat(''), isFalse);
      });

      // A repeat is not a tap: the sheet stays up, waiting for a real one.
      test('a repeat keeps the sheet up and polls again, slowly', () async {
        session.began();
        await session.keepPolling();
        expect(waits, [IosReadSession.repeatPause]);
        expect(calls, ['restartPolling']);
      });

      test('no polling restarts once the scan was stopped', () async {
        session.began();
        session.stopped();
        await session.keepPolling();
        expect(calls, isEmpty);
      });

      test('a failed restart releases the session', () async {
        final failing = make(
          restartPolling: () async => throw Exception('no session'),
        )..began();
        await failing.keepPolling();
        expect(calls, ['invalidate alert=null error=null']);
      });
    });
  });

  group('which iOS errors stop the scan', () {
    test('Cancel stops it', () {
      expect(
        scanStopFor(NfcReaderErrorCodeIos.readerSessionInvalidationErrorUserCanceled),
        ScanStop.cancelled,
      );
    });

    test('the 60 s timeout stops it', () {
      expect(
        scanStopFor(NfcReaderErrorCodeIos.readerSessionInvalidationErrorSessionTimeout),
        ScanStop.timedOut,
      );
    });

    test('anything else is an error to retry', () {
      for (final code in [
        NfcReaderErrorCodeIos.readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
        NfcReaderErrorCodeIos.readerSessionInvalidationErrorSystemIsBusy,
      ]) {
        expect(scanStopFor(code), isNull, reason: code.name);
      }
    });
  });

  // Android sessions keep polling by themselves; arming there is unchanged.
  test('Android never waits, never repeats, is never touched', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    session.began();
    session.isRepeat('04A1B2');
    expect(session.isRepeat('04A1B2'), isFalse);
    await session.end(message: 'Chunk 1 of 3');
    await session.keepPolling();
    await session.invalidatedBySystem();
    await session.beforeBegin();
    expect(calls, isEmpty);
    expect(waits, isEmpty);
  });
}
