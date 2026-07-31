import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/cancellation_token.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/core/inspect/card_dump.dart';
import 'package:nfc_archiver/core/nfc/type2.dart';

import 'support/fake_chameleon_device.dart';

DumpCallbacks _noop() => DumpCallbacks(onUnit: (_, __, ___) {});

void main() {
  group('Mifare Classic', () {
    test('yields 64 units, classified by position', () async {
      final r = await dumpCard(FakeChameleonDevice.classic1k(), _noop());
      expect(r.units.length, 64);
      expect(r.meta.totalUnits, 64);
      expect(r.units[0].kind, UnitKind.manufacturer);
      expect(r.units[3].kind, UnitKind.trailer, reason: 'block % 4 == 3');
      expect(r.units[4].kind, UnitKind.data);
      expect(r.units[63].kind, UnitKind.trailer);
      expect(r.aborted, isFalse);
      expect(r.cardLost, isFalse);
    });

    test('every unit carries its sector number', () async {
      final r = await dumpCard(FakeChameleonDevice.classic1k(), _noop());
      expect(r.units[0].sector, 0);
      expect(r.units[4].sector, 1);
      expect(r.units[63].sector, 15);
    });

    test('an unreadable sector is reported, not fatal, and the dump continues',
        () async {
      // A card with one custom-keyed sector is still mostly readable, and that
      // partial view is itself the diagnostic.
      final dev = FakeChameleonDevice.classic1k(
        sectorKeys: {1: Uint8List.fromList(const [9, 9, 9, 9, 9, 9])},
      );
      final r = await dumpCard(dev, _noop());
      expect(r.units.length, 64, reason: 'every block is still reported');
      expect(r.units[4].failure, UnitFailure.authFailed);
      expect(r.units[4].bytes, isNull);
      expect(r.units[0].bytes, isNotNull, reason: 'other sectors unaffected');
      expect(r.cardLost, isFalse, reason: 'auth failure is not a lost card');
    });

    test('progress counts reach the total', () async {
      final seen = <int>[];
      var total = 0;
      await dumpCard(
        FakeChameleonDevice.classic1k(),
        DumpCallbacks(onUnit: (_, done, t) {
          seen.add(done);
          total = t;
        }),
      );
      expect(seen.first, 1);
      expect(seen.last, 64);
      expect(total, 64);
    });

    test('a card removed mid-dump marks cardLost and fills the rest as notRead',
        () async {
      final dev = FakeChameleonDevice.classic1k()..failFromBlock(10);
      final r = await dumpCard(dev, _noop());
      expect(r.cardLost, isTrue);
      expect(r.units.length, 64, reason: 'the remainder is reported, not dropped');
      expect(r.units[9].bytes, isNotNull);
      expect(r.units[10].failure, UnitFailure.notRead);
      expect(r.units.last.failure, UnitFailure.notRead);
    });

    test('cancelling mid-dump returns a partial result marked aborted', () async {
      final token = CancellationToken();
      final r = await dumpCard(
        FakeChameleonDevice.classic1k(),
        DumpCallbacks(onUnit: (_, done, __) {
          if (done == 5) token.cancel();
        }),
        token: token,
      );
      expect(r.aborted, isTrue);
      expect(r.units.length, lessThan(64));
      expect(r.units, isNotEmpty, reason: 'a partial dump is still an artefact');
    });
  });

  group('NTAG', () {
    test('groups four pages per unit and marks group 0 as cc', () async {
      final r = await dumpCard(FakeChameleonDevice.ntag215(), _noop());
      expect(r.units[0].kind, UnitKind.cc,
          reason: 'group 0 carries UID, lock bytes AND the capability container');
      expect(r.units[0].index, 0);
      expect(r.units[1].index, 4, reason: 'index is the STARTING page');
      expect(r.units[1].kind, UnitKind.data);
      expect(r.units[0].sector, isNull, reason: 'NTAG has no sectors');
    });

    test('unit count is ceil(totalPages / 4) and the medium is detected', () async {
      final r = await dumpCard(FakeChameleonDevice.ntag215(), _noop());
      expect(r.meta.medium, NtagType.ntag215);
      // NTAG215 is 135 pages -> 34 groups.
      expect(r.units.length, 34);
      expect(r.meta.totalUnits, 34);
    });

    test('a short read on the FINAL group is accepted, not a failure', () async {
      // A real READ wraps to page 0 near the end of memory; the fake returns a
      // short slice instead. Either way the last group is legitimately short,
      // and treating that as marginal RF would flag every healthy NTAG.
      final r = await dumpCard(FakeChameleonDevice.ntag215(), _noop());
      expect(r.units.last.failure, isNull);
      expect(r.units.last.bytes, isNotNull);
      expect(r.units.last.bytes!.length, lessThanOrEqualTo(16));
    });

    test('a tag that does not answer GET_VERSION is unsupported', () async {
      final dev = FakeChameleonDevice.ntag215()..failGetVersion();
      expect(() => dumpCard(dev, _noop()),
          throwsA(isA<UnsupportedTagException>()));
    });

    test('an unrecognised storage byte is unsupported, and says so', () async {
      final dev = FakeChameleonDevice.ntag215()..overrideStorageByte(0x99);
      await expectLater(
        dumpCard(dev, _noop()),
        throwsA(isA<UnsupportedTagException>()),
      );
    });
  });

  group('routing', () {
    test('an unsupported SAK is rejected, and the message names it', () async {
      final dev = FakeChameleonDevice.classic1k()..overrideSak(0x20);
      await expectLater(
        dumpCard(dev, _noop()),
        throwsA(
          isA<UnsupportedTagException>().having(
            (e) => e.message, 'message', contains('20'),
          ),
        ),
      );
    });

    test('an empty field is a timeout, not a crash', () async {
      final dev = FakeChameleonDevice.classic1k()..removeCard();
      expect(() => dumpCard(dev, _noop()), throwsA(isA<TagTimeoutException>()));
    });

    test('onMeta fires before the first unit', () async {
      // Identity must be on screen in about a second rather than after ~64 BLE
      // round trips, so onMeta has to precede any read.
      var metaSeen = false;
      var metaWasFirst = true;
      await dumpCard(
        FakeChameleonDevice.classic1k(),
        DumpCallbacks(
          onMeta: (_) => metaSeen = true,
          onUnit: (_, __, ___) {
            if (!metaSeen) metaWasFirst = false;
          },
        ),
      );
      expect(metaWasFirst, isTrue);
    });
  });
}
