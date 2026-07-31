import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/inspect/nfar_describe.dart';
import 'package:nfc_archiver/core/models/chunk.dart';

import 'support/helpers.dart';

/// describeNfar exists to be MORE tolerant than Chunk.fromBytes. Where the
/// production decoder throws, this reports — because in an inspector the
/// malformed header IS the information the user came for.
///
/// Every test below therefore asserts a *described* result. If any of them ever
/// needs `throwsA`, the function has lost its reason to exist.
void main() {
  group('absent', () {
    test('a blank card is reported absent, not thrown', () {
      final d = describeNfar(Uint8List(64));
      expect(d, isA<NfarAbsent>());
      expect((d as NfarAbsent).reason, isNotEmpty);
    });

    test('too few bytes to judge says so, with the count', () {
      final d = describeNfar(Uint8List.fromList([0x4e, 0x46])) as NfarAbsent;
      expect(d.reason, contains('2 bytes'));
    });

    test('a magic mismatch reports what it actually saw', () {
      final d = describeNfar(
        Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x01]),
      ) as NfarAbsent;
      expect(d.reason, contains('DE AD BE EF'));
      expect(d.reason, contains('NFAR'));
    });

    test('an unsupported version is named', () {
      final bytes = validChunkBytes();
      bytes[4] = 0x09;
      final d = describeNfar(bytes) as NfarAbsent;
      expect(d.reason, contains('9'));
    });

    test('a truncated header says how far it got', () {
      // Correct magic and version, then nothing — exactly the input
      // Chunk.fromBytes rejects outright.
      final d = describeNfar(
        Uint8List.fromList([0x4e, 0x46, 0x41, 0x52, 0x01, 0x00]),
      ) as NfarAbsent;
      expect(d.reason, contains('6'));
      expect(d.reason, contains('28'));
    });
  });

  group('present', () {
    test('a valid chunk reports a matching CRC and no warnings', () {
      final d = describeNfar(validChunkBytes()) as NfarPresent;
      expect(d.crcValid, isTrue);
      expect(d.crcStored, equals(d.crcComputed));
      expect(d.warnings, isEmpty);
      expect(d.payloadSize, 32);
      expect(d.totalLength, 32 + 32);
      expect(d.version, 1);
      expect(d.archiveId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('a corrupted payload reports crcValid false WITHOUT throwing', () {
      final bytes = validChunkBytes();
      bytes[30] ^= 0xff; // inside the payload
      final d = describeNfar(bytes) as NfarPresent;
      expect(d.crcValid, isFalse);
      expect(d.crcStored, isNot(equals(d.crcComputed)));
    });

    test('a payload cut short reports a NULL crc, not false', () {
      // Nothing to compare against is not the same fact as a mismatch, and an
      // inspector must never claim corruption it cannot actually prove.
      final full = validChunkBytes();
      final d = describeNfar(
        Uint8List.sublistView(full, 0, full.length - 4),
      ) as NfarPresent;
      expect(d.crcValid, isNull);
      expect(d.crcStored, isNull);
      expect(d.crcComputed, isNull);
    });

    test('a declared length past the card capacity is warned about', () {
      final d = describeNfar(validChunkBytes(), capacityBytes: 16)
          as NfarPresent;
      expect(d.warnings.join(), contains('capacity'));
    });

    test('unknown flag bits are warned about but still parsed', () {
      final bytes = validChunkBytes();
      bytes[5] = 0x80;
      final d = describeNfar(bytes) as NfarPresent;
      expect(d.flags, 0x80);
      expect(d.compressed, isFalse);
      expect(d.encrypted, isFalse);
      expect(d.warnings.join(), contains('flag'));
    });

    test('compression and encryption flags decode', () {
      final bytes = validChunkBytes();
      bytes[5] = 0x03;
      final d = describeNfar(bytes) as NfarPresent;
      expect(d.compressed, isTrue);
      expect(d.encrypted, isTrue);
      expect(d.warnings, isEmpty);
    });

    test('a chunk index out of range for the chunk count is warned about', () {
      final bytes = validChunkBytes();
      bytes[22] = 0x00; bytes[23] = 0x02; // totalChunks = 2
      bytes[24] = 0x00; bytes[25] = 0x05; // chunkIndex  = 5
      final d = describeNfar(bytes) as NfarPresent;
      expect(d.warnings.join(), contains('out of range'));
    });
  });

  group('tolerance is the point', () {
    // This group is the function's reason to exist, asserted rather than
    // asserted-about. If a future refactor makes describeNfar delegate to
    // Chunk.fromBytes, these fail — which is exactly the intent.
    test('inputs the production decoder REJECTS are still described', () {
      final rejected = <String, Uint8List>{
        'truncated header': Uint8List.fromList(
          [0x4e, 0x46, 0x41, 0x52, 0x01, 0x00],
        ),
        'bad magic': Uint8List.fromList(
          [0xDE, 0xAD, 0xBE, 0xEF, ...List<int>.filled(40, 0)],
        ),
        'blank card': Uint8List(64),
      };

      for (final entry in rejected.entries) {
        expect(
          () => Chunk.fromBytes(entry.value),
          throwsA(anything),
          reason: '${entry.key}: precondition — the production decoder rejects this',
        );
        expect(
          () => describeNfar(entry.value),
          returnsNormally,
          reason: '${entry.key}: describeNfar must describe it instead',
        );
      }
    });

    test('a corrupt CRC is a finding here and a throw there', () {
      final bytes = validChunkBytes();
      bytes[30] ^= 0xff;
      // Chunk.fromBytes validates nothing about the CRC, so this one does NOT
      // throw — but describeNfar is the only path that reports the mismatch.
      final d = describeNfar(bytes) as NfarPresent;
      expect(d.crcValid, isFalse,
          reason: 'the inspector is where a bad CRC becomes visible');
    });
  });
}
