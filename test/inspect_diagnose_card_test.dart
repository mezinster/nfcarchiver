import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/inspect/diagnose_card.dart';

import 'support/fake_chameleon_device.dart';

void main() {
  test('a well-formed 4-byte UID card has a consistent BCC', () async {
    final d = await diagnoseCard(FakeChameleonDevice.classic1k());
    expect(d.uidCl1, equals([0xDE, 0xAD, 0xBE, 0xEF]));
    expect(d.bccComputed, 0xDE ^ 0xAD ^ 0xBE ^ 0xEF);
    expect(d.bccReturned, equals(d.bccComputed));
    expect(d.bccValid, isTrue);
    expect(d.isCascade, isFalse);
    expect(d.atqa.length, 2);
  });

  test('a 7-byte UID card is reported as cascade', () async {
    // uidCl1[0] == 0x88 is the cascade tag: this is anticollision level 1 of a
    // longer UID, not the UID itself.
    final d = await diagnoseCard(FakeChameleonDevice.ntag215());
    expect(d.isCascade, isTrue);
    expect(d.uidCl1[0], 0x88);
    expect(d.bccValid, isTrue, reason: 'a cascade UID still has a valid BCC');
  });

  test('an inconsistent BCC is reported, not thrown — that IS the finding', () async {
    // A self-inconsistent BCC means a malformed or UID-writable "magic" card,
    // which is exactly what someone reaches for an inspector to discover.
    final d = await diagnoseCard(FakeChameleonDevice.classic1k()..corruptBcc());
    expect(d.bccValid, isFalse);
    expect(d.bccReturned, isNot(equals(d.bccComputed)));
  });

  test('a short anticollision response is an error, not a silent guess', () async {
    final dev = FakeChameleonDevice.classic1k()..truncateAnticollision();
    expect(() => diagnoseCard(dev), throwsA(anything));
  });

  test('a card that does not answer at all propagates the failure', () async {
    // runInspection catches this and continues — the probe is advisory,
    // because readBlock performs its own select.
    final dev = FakeChameleonDevice.classic1k()..failAnticollision();
    expect(() => diagnoseCard(dev), throwsA(anything));
  });
}
