import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/inspect/card_dump.dart';
import 'package:nfc_archiver/core/inspect/nfar_source.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/nfc/ndef_bytes.dart';
import 'package:nfc_archiver/core/nfc/type2.dart';

import 'support/helpers.dart';

/// Build 64 Classic units whose usable blocks carry [data].
List<DumpUnit> _classicUnits(Uint8List data, {Set<int> authFailed = const {}}) {
  final units = <DumpUnit>[];
  var offset = 0;
  for (var block = 0; block < 64; block++) {
    final sector = block ~/ 4;
    final kind = block == 0
        ? UnitKind.manufacturer
        : (block % 4 == 3 ? UnitKind.trailer : UnitKind.data);
    if (authFailed.contains(block)) {
      units.add(DumpUnit(
          index: block,
          sector: sector,
          kind: kind,
          failure: UnitFailure.authFailed));
      continue;
    }
    final bytes = Uint8List(blockSize);
    if (usableBlockIndexes.contains(block) && offset < data.length) {
      final take = (data.length - offset).clamp(0, blockSize);
      bytes.setRange(0, take, data, offset);
      offset += take;
    }
    units.add(
        DumpUnit(index: block, sector: sector, kind: kind, bytes: bytes));
  }
  return units;
}

/// Build NTAG units carrying [memory] from page 4 onward.
List<DumpUnit> _ntagUnits(Uint8List memory, {int groups = 34}) {
  final units = <DumpUnit>[
    DumpUnit(index: 0, kind: UnitKind.cc, bytes: Uint8List(16)),
  ];
  var offset = 0;
  for (var g = 1; g < groups; g++) {
    final bytes = Uint8List(16);
    if (offset < memory.length) {
      final take = (memory.length - offset).clamp(0, 16);
      bytes.setRange(0, take, memory, offset);
      offset += take;
    }
    units.add(
        DumpUnit(index: g * 4, kind: UnitKind.data, bytes: bytes));
  }
  return units;
}

void main() {
  group('Mifare Classic', () {
    test('usable blocks are concatenated; block 0 and trailers skipped', () {
      final chunk = validChunkBytes();
      final src = nfarBytesSoFar(_classicUnits(chunk), isClassic: true);
      expect(src, isA<SourceBytes>());
      final bytes = (src as SourceBytes).bytes;
      expect(bytes.sublist(0, 4), equals('NFAR'.codeUnits));
      expect(bytes.sublist(0, chunk.length), equals(chunk));
    });

    test('a gap truncates the stream — bytes after a hole are meaningless', () {
      final chunk = validChunkBytes(payloadLength: 300);
      // Block 5 is usable and lands early in the stream.
      final src = nfarBytesSoFar(
        _classicUnits(chunk, authFailed: {5}),
        isClassic: true,
      ) as SourceBytes;
      expect(src.bytes.length, lessThan(chunk.length));
    });

    test('every usable block auth-failing reports unreadable, NOT "0 bytes"', () {
      // The dump DID read those blocks; they came back auth-failed. Saying
      // "0 bytes read" would state something false about a card that was read.
      final units = _classicUnits(
        validChunkBytes(),
        authFailed: usableBlockIndexes.toSet(),
      );
      final src = nfarBytesSoFar(units, isClassic: true);
      expect(src, isA<SourceUnreadable>());
      expect((src as SourceUnreadable).reason, contains('key'));
    });

    test('an empty unit list is simply no bytes yet', () {
      final src = nfarBytesSoFar(const [], isClassic: true);
      expect(src, isA<SourceBytes>());
      expect((src as SourceBytes).bytes, isEmpty);
    });
  });

  group('NTAG', () {
    test('the TLV and NDEF envelope are unwrapped to reach the chunk', () {
      // Concatenated raw pages start with the TLV header, not NFAR magic —
      // without the unwrap every NTAG card reports "not NFAR".
      final chunk = validChunkBytes();
      final memory = wrapType2Tlv(encodeNdefMime(chunk));
      final src = nfarBytesSoFar(_ntagUnits(memory), isClassic: false);
      expect(src, isA<SourceBytes>());
      expect((src as SourceBytes).bytes, equals(chunk));
    });

    test('an incomplete TLV reports no-envelope, not "not NFAR"', () {
      final memory = wrapType2Tlv(encodeNdefMime(validChunkBytes()));
      // Only the first data group has arrived so far.
      final src = nfarBytesSoFar(
        _ntagUnits(memory, groups: 2),
        isClassic: false,
      );
      expect(src, isA<SourceNoEnvelope>());
    });

    test('a complete NDEF record with a foreign MIME type reports foreign', () {
      // A permanent fact about a fully-read tag — structurally different from
      // "the TLV has not arrived yet", so the two must not share a message.
      final foreign = encodeNdefMime(Uint8List(8));
      foreign[5] ^= 0xff; // break the MIME type string
      final src =
          nfarBytesSoFar(_ntagUnits(wrapType2Tlv(foreign)), isClassic: false);
      expect(src, isA<SourceForeign>());
    });

    test('the three failure reasons are all distinct', () {
      final reasons = <String>{};
      final memory = wrapType2Tlv(encodeNdefMime(validChunkBytes()));
      reasons.add((nfarBytesSoFar(_ntagUnits(memory, groups: 2),
              isClassic: false) as SourceNoEnvelope)
          .reason);
      final foreign = encodeNdefMime(Uint8List(8))..[5] ^= 0xff;
      reasons.add((nfarBytesSoFar(_ntagUnits(wrapType2Tlv(foreign)),
              isClassic: false) as SourceForeign)
          .reason);
      reasons.add((nfarBytesSoFar(
                  _classicUnits(validChunkBytes(),
                      authFailed: usableBlockIndexes.toSet()),
                  isClassic: true) as SourceUnreadable)
          .reason);
      expect(reasons.length, 3,
          reason: 'three different facts must not share a message');
    });
  });
}
