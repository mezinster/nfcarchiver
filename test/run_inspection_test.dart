import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/cancellation_token.dart';
import 'package:nfc_archiver/features/inspect/domain/inspect_sink.dart';
import 'package:nfc_archiver/features/inspect/domain/run_inspection.dart';

import 'support/fake_chameleon_device.dart';
import 'support/helpers.dart';

class RecordingSink implements InspectSink {
  final rows = <String>[];
  String? identity;
  String? nfar;
  String? progress;
  String? report;
  String? status;

  /// Fires the first time a row arrives, for asserting ORDERING.
  void Function()? onFirstRow;

  /// Fires per row with the running count.
  void Function(int count)? onRow;

  @override
  void appendRow(String line) {
    rows.add(line);
    if (rows.length == 1) onFirstRow?.call();
    onRow?.call(rows.length);
  }

  @override
  void setIdentity(String text) => identity = text;
  @override
  void setNfar(String text) => nfar = text;
  @override
  void setProgress(String text) => progress = text;
  @override
  void setReport(String text) => report = text;
  @override
  void setStatus(String text) => status = text;
}

void main() {
  test('identity is reported BEFORE the first block is read', () async {
    // onMeta must fire before any read, or the user stares at an empty dialog
    // for ~64 BLE round trips.
    final sink = RecordingSink();
    String? identityAtFirstRow;
    sink.onFirstRow = () => identityAtFirstRow = sink.identity;

    await runInspection(FakeChameleonDevice.classic1k(), sink);

    expect(identityAtFirstRow, isNotNull);
    expect(identityAtFirstRow, contains('Mifare Classic 1K'));
  });

  test('a full Classic inspection emits a row per block, plus a report',
      () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k(), sink);
    expect(sink.rows.length, 64);
    expect(sink.report, isNotNull);
    expect(sink.nfar, isNotNull);
    expect(sink.status, isNotNull);
  });

  test('a 4K card reports 256 rows and names itself 4K', () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic4k(), sink);
    expect(sink.rows.length, 256);
    expect(sink.identity, contains('Mifare Classic 4K'));
  });

  test('a 3,000 B chunk on a 4K card is a valid chunk, CRC ok', () async {
    final dev = FakeChameleonDevice.classic4k()
      ..writeNfar(validChunkBytes(payloadLength: 3000));
    final sink = RecordingSink();
    await runInspection(dev, sink);
    expect(sink.nfar, contains('NFAR'));
    expect(sink.nfar, isNot(contains('not NFAR')));
    expect(sink.nfar, isNot(contains('MISMATCH')));
    expect(sink.nfar!.toLowerCase(), contains('ok'));
    expect(sink.nfar!.toLowerCase(), isNot(contains('exceeds')));
  });

  test('a 4K card (SAK 0x19, a 2K) gets the unsupported message', () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic4k(sak: 0x19), sink);
    expect(sink.status, contains('0x19'));
    expect(sink.rows, isEmpty);
  });

  test('a failed anticollision does NOT stop the dump', () async {
    // The probe is advisory: readBlock performs its own select, so a card that
    // refuses anticollision can still be dumped in full.
    final sink = RecordingSink();
    await runInspection(
      FakeChameleonDevice.classic1k()..failAnticollision(),
      sink,
    );
    expect(sink.rows.length, 64);
    expect(sink.identity, contains('identity unavailable'));
  });

  test('an unsupported tag keeps its SPECIFIC message', () async {
    // For an inspector the SAK value in that message IS the result, so a
    // generic "unsupported tag" string would discard the finding.
    final sink = RecordingSink();
    await runInspection(
      FakeChameleonDevice.classic1k()..overrideSak(0x20),
      sink,
    );
    expect(sink.status, contains('20'));
  });

  test('an empty field is reported, not thrown', () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k()..removeCard(), sink);
    expect(sink.status, isNotNull);
    expect(sink.rows, isEmpty);
  });

  test('cancellation reports stopped and still leaves a usable report',
      () async {
    final sink = RecordingSink();
    final token = CancellationToken();
    sink.onRow = (n) {
      if (n == 5) token.cancel();
    };

    await runInspection(FakeChameleonDevice.classic1k(), sink, token: token);

    expect(sink.rows.length, lessThan(64));
    expect(sink.report, isNotNull,
        reason: 'a partial dump is still a usable artefact');
    expect(sink.status, isNot(contains('complete')));
  });

  test('a card removed mid-dump is reported as lost, not as success', () async {
    final sink = RecordingSink();
    await runInspection(
      FakeChameleonDevice.classic1k()..failFromBlock(10),
      sink,
    );
    expect(sink.status, contains('field'));
  });

  test('an NTAG chunk is described from the unwrapped TLV, not raw pages',
      () async {
    // Concatenated raw pages begin with the TLV header, so without the unwrap
    // every NTAG card would be reported "not NFAR".
    final dev = FakeChameleonDevice.ntag215()
      ..writeNfar(validChunkBytes());
    final sink = RecordingSink();
    await runInspection(dev, sink);
    expect(sink.nfar, contains('NFAR'));
    expect(sink.nfar, isNot(contains('not NFAR')));
  });

  test('a Classic card holding a chunk has its CRC verified', () async {
    final dev = FakeChameleonDevice.classic1k();
    dev.writeNfar(validChunkBytes());
    final sink = RecordingSink();
    await runInspection(dev, sink);
    expect(sink.nfar, contains('CRC32'));
    expect(sink.nfar, contains('OK'));
  });

  test('progress counts up to the total', () async {
    final sink = RecordingSink();
    await runInspection(FakeChameleonDevice.classic1k(), sink);
    expect(sink.progress, contains('64'));
  });
}
