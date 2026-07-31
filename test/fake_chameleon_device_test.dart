import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';

import 'support/fake_chameleon_device.dart';

void main() {
  test('a Classic card round-trips a block through the fake', () async {
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();
    final data = Uint8List.fromList(List<int>.generate(16, (i) => i));
    await dev.writeBlock(4, factoryKeyA, data);
    expect(await dev.readBlock(4, factoryKeyA), equals(data));
  });

  test('a sector with a non-factory key raises CardAuthException', () async {
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {1: Uint8List.fromList(const [1, 2, 3, 4, 5, 6])},
    );
    await dev.connect();
    // Block 4 is in sector 1.
    expect(
      () => dev.readBlock(4, factoryKeyA),
      throwsA(isA<CardAuthException>()),
    );
  });

  test('an unaffected sector still reads when a neighbour is locked', () async {
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {1: Uint8List.fromList(const [1, 2, 3, 4, 5, 6])},
    );
    await dev.connect();
    expect((await dev.readBlock(1, factoryKeyA)).length, 16);
  });

  test('scanTag reports SAK 0x08 for Classic and 0x00 for NTAG', () async {
    expect((await FakeChameleonDevice.classic1k().scanTag())!.sak, 0x08);
    expect((await FakeChameleonDevice.ntag215().scanTag())!.sak, 0x00);
  });

  test('an empty field returns null rather than throwing', () async {
    final dev = FakeChameleonDevice.classic1k()..removeCard();
    expect(await dev.scanTag(), isNull);
  });

  test('an NTAG READ returns four pages', () async {
    final dev = FakeChameleonDevice.ntag215();
    await dev.connect();
    final resp = await dev.transceive14a(
      Uint8List.fromList(const [0x30, 0x04]),
      autoSelect: true,
      appendCrc: true,
    );
    expect(resp.length, 16, reason: 'a READ returns 4 pages of 4 bytes');
  });

  test('the fake does NOT wrap at the end of memory', () async {
    // A real NTAG READ wraps around to page 0; this fake returns a short slice
    // instead. That difference is deliberate — it is what exercises the
    // "a short read is legitimate on the FINAL group only" branch in dumpCard.
    // Do not "fix" this to wrap: doing so silently removes that test's value.
    final dev = FakeChameleonDevice.ntag215();
    await dev.connect();
    final last = dev.totalPages - 2;
    final resp = await dev.transceive14a(
      Uint8List.fromList([0x30, last]),
      autoSelect: true,
      appendCrc: true,
    );
    expect(resp.length, lessThan(16));
  });

  test('a Classic write is rejected once writes are set to corrupt', () async {
    final dev = FakeChameleonDevice.classic1k()..corruptWrites();
    await dev.connect();
    final data = Uint8List.fromList(List<int>.filled(16, 0xAB));
    await dev.writeBlock(4, factoryKeyA, data);
    expect(await dev.readBlock(4, factoryKeyA), isNot(equals(data)),
        reason: 'corruptWrites() exists so write-verify failures are testable');
  });

  test('failFromBlock makes every block from N onward throw', () async {
    final dev = FakeChameleonDevice.classic1k()..failFromBlock(10);
    await dev.connect();
    expect((await dev.readBlock(9, factoryKeyA)).length, 16);
    expect(() => dev.readBlock(10, factoryKeyA), throwsA(isA<CardReadException>()));
  });
}
