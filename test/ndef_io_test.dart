import 'dart:convert';
import 'dart:typed_data';

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
}
