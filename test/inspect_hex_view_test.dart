import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/inspect/card_dump.dart';
import 'package:nfc_archiver/core/inspect/hex_view.dart';
import 'package:nfc_archiver/core/inspect/nfar_describe.dart';
import 'package:nfc_archiver/core/nfc/type2.dart';

/// Byte i of block b, matching webapp/test/write_inspect_fixture.ts exactly.
Uint8List _blockBytes(int b) =>
    Uint8List.fromList(List<int>.generate(16, (i) => (0x42 + b + i) & 0xff));

/// The same structures the TypeScript fixture writer builds. Kept in lockstep
/// by hand rather than by running two fake devices: this test pins the
/// FORMATTERS, and coupling two independent fakes would make it fail for
/// reasons that have nothing to do with formatting.
({DumpMeta meta, IdentityDiagnosis diag, NfarDescription nfar, List<DumpUnit> units})
    _fixtureInput() {
  const bcc = 0xde ^ 0xad ^ 0xbe ^ 0xef;

  final meta = DumpMeta(
    sak: 0x08,
    uid: Uint8List.fromList(const [0xde, 0xad, 0xbe, 0xef]),
    totalUnits: 64,
  );

  final diag = IdentityDiagnosis(
    // ATQA 0x0004 as a Classic 1K actually puts it on the wire: LSB first.
    atqa: Uint8List.fromList(const [0x04, 0x00]),
    uidCl1: Uint8List.fromList(const [0xde, 0xad, 0xbe, 0xef]),
    bccReturned: bcc,
    bccComputed: bcc,
    bccValid: true,
    isCascade: false,
  );

  final units = <DumpUnit>[];
  for (var block = 0; block < 12; block++) {
    final kind = block == 0
        ? UnitKind.manufacturer
        : (block % 4 == 3 ? UnitKind.trailer : UnitKind.data);
    final sector = block ~/ 4;
    if (block == 5) {
      units.add(DumpUnit(
          index: block, sector: sector, kind: kind, failure: UnitFailure.authFailed));
    } else if (block == 6) {
      units.add(DumpUnit(
          index: block, sector: sector, kind: kind, failure: UnitFailure.shortRead));
    } else if (block == 11) {
      units.add(DumpUnit(
          index: block, sector: sector, kind: kind, failure: UnitFailure.notRead));
    } else {
      units.add(DumpUnit(
          index: block, sector: sector, kind: kind, bytes: _blockBytes(block)));
    }
  }
  units.add(DumpUnit(index: 0, kind: UnitKind.cc, bytes: _blockBytes(99)));

  const nfar = NfarPresent(
    version: 1,
    flags: 0x03,
    compressed: true,
    encrypted: true,
    archiveId: 'a0a1a2a3-a4a5-a6a7-a8a9-aaabacadaeaf',
    chunkIndex: 2,
    totalChunks: 8,
    payloadSize: 720,
    totalLength: 752,
    crcStored: 0x1234abcd,
    crcComputed: 0x1234abcd,
    crcValid: true,
    warnings: ['declared length 752 B exceeds the tag’s 700 B capacity'],
  );

  return (meta: meta, diag: diag, nfar: nfar, units: units);
}

void main() {
  test('formatReport matches the TypeScript byte for byte', () {
    // The strongest evidence available that this port is faithful rather than
    // merely plausible — the same technique that verified card_layout.dart.
    // Regenerate with:
    //   cd webapp && npx tsc && node dist/test/write_inspect_fixture.js
    final expected =
        File('test/fixtures/inspect_report.txt').readAsStringSync();
    final f = _fixtureInput();
    expect(formatReport(f.meta, f.diag, f.nfar, f.units), equals(expected));
  });

  group('formatUnitRow', () {
    test('a Classic data block shows hex, ASCII and no note', () {
      final row = formatUnitRow(DumpUnit(
          index: 1, sector: 0, kind: UnitKind.data, bytes: _blockBytes(1)));
      expect(row, startsWith('s 0 b 1'));
      expect(row, contains('43 44 45'));
      expect(row, isNot(contains('←')));
    });

    test('structural blocks are annotated', () {
      String note(UnitKind k) => formatUnitRow(
          DumpUnit(index: 0, sector: 0, kind: k, bytes: _blockBytes(0)));
      expect(note(UnitKind.manufacturer), contains('manufacturer block'));
      expect(note(UnitKind.trailer), contains('sector trailer'));
      expect(note(UnitKind.cc), contains('capability container'));
    });

    test('an NTAG unit uses a page label, not a sector one', () {
      final row = formatUnitRow(
          DumpUnit(index: 8, kind: UnitKind.data, bytes: _blockBytes(8)));
      expect(row, startsWith('pg   8'));
    });

    test('each failure states what it means, not just that it failed', () {
      String row(UnitFailure f) => formatUnitRow(
          DumpUnit(index: 4, sector: 1, kind: UnitKind.data, failure: f));
      expect(row(UnitFailure.authFailed), contains('non-factory key'));
      expect(row(UnitFailure.notRead), contains('card left the field'));
      expect(row(UnitFailure.shortRead), contains('marginal coupling'));
    });

    test('non-printable bytes render as dots, never as control characters', () {
      // A raw control byte in a pasted report can corrupt a terminal or an
      // issue tracker, so the ASCII column is sanitised.
      final row = formatUnitRow(DumpUnit(
        index: 0,
        sector: 0,
        kind: UnitKind.data,
        bytes: Uint8List.fromList(List<int>.filled(16, 0x07)),
      ));
      expect(row, contains('................'));
      expect(row.contains(String.fromCharCode(0x07)), isFalse);
    });
  });

  group('formatNfar', () {
    test('an absent chunk carries the reason through', () {
      expect(formatNfar(const NfarAbsent('magic mismatch: got DE AD')),
          contains('magic mismatch: got DE AD'));
    });

    test('a pending CRC says pending, never OK or MISMATCH', () {
      const d = NfarPresent(
        version: 1, flags: 0, compressed: false, encrypted: false,
        archiveId: 'a0a1a2a3-a4a5-a6a7-a8a9-aaabacadaeaf',
        chunkIndex: 0, totalChunks: 1, payloadSize: 10, totalLength: 42,
        crcStored: null, crcComputed: null, crcValid: null, warnings: [],
      );
      final out = formatNfar(d);
      expect(out, contains('pending'));
      expect(out, isNot(contains('MISMATCH')));
    });

    test('a CRC mismatch is stated in full so it can be pasted', () {
      const d = NfarPresent(
        version: 1, flags: 0, compressed: false, encrypted: false,
        archiveId: 'a0a1a2a3-a4a5-a6a7-a8a9-aaabacadaeaf',
        chunkIndex: 0, totalChunks: 1, payloadSize: 10, totalLength: 42,
        crcStored: 0x11111111, crcComputed: 0x22222222, crcValid: false,
        warnings: [],
      );
      final out = formatNfar(d);
      expect(out, contains('11111111'));
      expect(out, contains('22222222'));
      expect(out, contains('MISMATCH'));
    });
  });

  group('formatIdentity', () {
    test('a failed anticollision says the dump may still work', () {
      final meta = DumpMeta(
          sak: 0x08, uid: Uint8List.fromList(const [1, 2, 3, 4]), totalUnits: 64);
      expect(formatIdentity(meta, null), contains('dump may still work'));
    });

    test('a cascade UID is normal on NTAG and a fault on Classic', () {
      IdentityDiagnosis cascade() => IdentityDiagnosis(
            atqa: Uint8List.fromList(const [0x00, 0x44]),
            uidCl1: Uint8List.fromList(const [0x88, 1, 2, 3]),
            bccReturned: 0x88 ^ 1 ^ 2 ^ 3,
            bccComputed: 0x88 ^ 1 ^ 2 ^ 3,
            bccValid: true,
            isCascade: true,
          );
      final classic = DumpMeta(
          sak: 0x08, uid: Uint8List.fromList(const [1, 2, 3, 4]), totalUnits: 64);
      final ntag = DumpMeta(
        sak: 0x00,
        uid: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7]),
        totalUnits: 34,
        ntagType: NtagType.ntag215,
      );
      expect(formatIdentity(classic, cascade()), contains('not a 4-byte'));
      expect(formatIdentity(ntag, cascade()), contains('normal for NTAG'));
    });

    test('an inconsistent BCC names the magic-card verdict', () {
      final meta = DumpMeta(
          sak: 0x08, uid: Uint8List.fromList(const [1, 2, 3, 4]), totalUnits: 64);
      final bad = IdentityDiagnosis(
        atqa: Uint8List.fromList(const [0x04, 0x00]),
        uidCl1: Uint8List.fromList(const [1, 2, 3, 4]),
        bccReturned: 0x00,
        bccComputed: 0x04,
        bccValid: false,
        isCascade: false,
      );
      expect(formatIdentity(meta, bad), contains('magic'));
    });

    test('a malformed ATQA is flagged rather than passed off as a card property',
        () {
      // Mirrors the TypeScript test of the same name. The shared fixture pins
      // only a well-formed ATQA, so without this the two ports could diverge on
      // the malformed path with nothing to notice.
      final meta = DumpMeta(
          sak: 0x08, uid: Uint8List.fromList(const [1, 2, 3, 4]), totalUnits: 64);
      IdentityDiagnosis withAtqa(List<int> bytes) => IdentityDiagnosis(
            atqa: Uint8List.fromList(bytes),
            uidCl1: Uint8List.fromList(const [1, 2, 3, 4]),
            bccReturned: 1 ^ 2 ^ 3 ^ 4,
            bccComputed: 1 ^ 2 ^ 3 ^ 4,
            bccValid: true,
            isCascade: false,
          );

      final short = formatIdentity(meta, withAtqa(const [0x3f]));
      expect(short, contains('3F'), reason: 'the offending bytes must survive');
      expect(short, contains('malformed (expected 2 bytes, got 1)'));
      expect(formatIdentity(meta, withAtqa(const [])),
          contains('expected 2 bytes, got 0'));
      expect(formatIdentity(meta, withAtqa(const [0x04, 0x00, 0x99])),
          contains('expected 2 bytes, got 3'));

      // A well-formed ATQA carries no note, and a bad one is not fatal.
      expect(formatIdentity(meta, withAtqa(const [0x04, 0x00])),
          isNot(contains('malformed')));
      expect(short, contains('Verdict   BCC OK'));
    });
  });
}
