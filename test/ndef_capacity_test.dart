import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';

/// NDEF record overhead for one NFAR chunk, as written to a Type-2 tag:
/// 1 flags + 1 type length + 4 payload length (long form) + 33 MIME type.
const _ndefRecordOverhead = 6 + 33;

/// The NFC Forum Type-2 spec terminates the TLV area with a 0xFE byte. It has
/// to live inside the same NDEF data area as the message, so the writer must
/// reserve it.
const _terminatorTlv = 1;

void main() {
  group('maxPayloadForCapacity', () {
    test('leaves room for the 0xFE terminator TLV', () {
      // Android reports 492 for an NTAG215: the CC-declared 496 B data area
      // minus the 4-byte TLV header. Fitting a message of exactly 492 B leaves
      // nothing for the terminator, which is the bug this guards.
      for (final capacity in [144, 240, 492, 872, 1024]) {
        final payload = NfcTagType.maxPayloadForCapacity(capacity);
        final message = _ndefRecordOverhead + NfarHeaderSize.total + payload;
        expect(
          message + _terminatorTlv,
          lessThanOrEqualTo(capacity),
          reason: 'capacity $capacity: message $message + terminator overruns',
        );
      }
    });

    test('matches the web app so both writers chunk identically', () {
      // The web app's chunkPayloadForCapacity() measures the whole wrapped TLV
      // including the terminator, and yields 420 for an NTAG215. A card written
      // by either app must be interchangeable with one written by the other.
      expect(NfcTagType.maxPayloadForCapacity(492), 420);
    });

    test('is maximal — one more byte would not fit', () {
      const capacity = 492;
      final payload = NfcTagType.maxPayloadForCapacity(capacity);
      final oneMore =
          _ndefRecordOverhead + NfarHeaderSize.total + payload + 1 + _terminatorTlv;
      expect(oneMore, greaterThan(capacity),
          reason: 'payload is smaller than it needs to be');
    });

    test('never returns a negative payload for a tiny capacity', () {
      expect(NfcTagType.maxPayloadForCapacity(10), 0);
      expect(NfcTagType.maxPayloadForCapacity(0), 0);
    });
  });
}
