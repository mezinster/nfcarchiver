import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_io.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

/// The two places nfc_manager v4 changed meaning rather than just names.
///
/// The adapters themselves wrap `NdefAndroid`/`NdefIos`, which cannot be
/// constructed in a test — that is the whole reason [NdefIO] exists. So the
/// decisions are extracted as pure functions and pinned here; the adapters are
/// left as thin delegation with nothing to get wrong.
void main() {
  group('a tag with no message reads as empty, not as an error', () {
    // v3's `Ndef.read()` returned a non-null NdefMessage. v4's
    // `getNdefMessage()` / `readNdef()` return null for a tag that holds no
    // message. Surfacing that null would turn a blank tag into a crash at
    // `ndefToChunk`; the app's existing meaning is "no chunk here".

    test('null becomes a message with no records', () {
      expect(ndefMessageOrEmpty(null).records, isEmpty);
    });

    test('a real message passes through untouched', () {
      final message = NdefMessage(records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.media,
          type: ascii.encode('text/plain'),
          identifier: Uint8List(0),
          payload: ascii.encode('hi'),
        )
      ]);

      expect(ndefMessageOrEmpty(message), same(message));
    });
  });

  group('iOS writability is a tri-state, not a bool', () {
    // Android exposes `isWritable`. iOS exposes `NdefStatusIos`, and only
    // readWrite accepts a write — collapsing the other two to "writable" would
    // make the codec attempt a write that the tag rejects.

    test('readWrite is writable', () {
      expect(isWritableIosStatus(NdefStatusIos.readWrite), isTrue);
    });

    test('readOnly is not writable', () {
      expect(isWritableIosStatus(NdefStatusIos.readOnly), isFalse);
    });

    test('notSupported is not writable', () {
      expect(isWritableIosStatus(NdefStatusIos.notSupported), isFalse);
    });
  });
  group('iOS reports a blank tag as NFCError 403', () {
    final blank = PlatformException(
      code:
          'Error Domain=NFCError Code=403 "NDEF tag does not contain any NDEF message" '
          'UserInfo={NSLocalizedDescription=NDEF tag does not contain any NDEF message}',
      message: 'NFCError',
      details: 'Stacktrace: ["0   Runner   0x0000000104807470 Runner + 111728"]',
    );

    test('isEmptyNdefError recognises 403 only', () {
      expect(isEmptyNdefError(blank), isTrue);
      expect(
        isEmptyNdefError(PlatformException(
            code: 'Error Domain=NFCError Code=102 "Tag response error"')),
        isFalse,
      );
      expect(isEmptyNdefError(StateError('x')), isFalse);
    });

    test('readOrEmpty maps 403 to an empty message', () async {
      final m = await readOrEmpty(() async => throw blank);
      expect(m.records, isEmpty);
    });

    test('readOrEmpty maps null to an empty message', () async {
      final m = await readOrEmpty(() async => null);
      expect(m.records, isEmpty);
    });

    test('readOrEmpty rethrows other errors', () {
      expect(
        readOrEmpty(() async => throw PlatformException(
            code: 'Error Domain=NFCError Code=102 "x"')),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
