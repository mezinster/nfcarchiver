import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/inspect/presentation/providers/inspect_provider.dart';

import 'support/fake_chameleon_device.dart';
import 'support/helpers.dart';

void main() {
  test('state accumulates rows, identity, nfar and a report', () async {
    final n = InspectNotifier();
    await n.start(FakeChameleonDevice.classic1k());
    expect(n.state.rows.length, 64);
    expect(n.state.identity, isNotNull);
    expect(n.state.nfar, isNotNull);
    expect(n.state.report, isNotNull);
    expect(n.state.isRunning, isFalse);
  });

  test('a superseded run CANNOT write into the run that replaced it', () async {
    // This is the regression test for the web app's 67c4683. The failure is
    // NOT "cancel fails to set a flag" — it is run 1's already-scheduled
    // callbacks scribbling rows and progress into run 2's state.
    final n = InspectNotifier();
    final slow = FakeChameleonDevice.classic1k()
      ..delayPerBlock(const Duration(milliseconds: 5));

    final first = n.start(slow); // deliberately not awaited
    await pumpUntil(() => n.state.rows.isNotEmpty);

    // Supersede it with a fast run that completes on its own.
    await n.start(FakeChameleonDevice.classic1k());
    final rowsAfterSecond = n.state.rows.length;
    final reportAfterSecond = n.state.report;

    await first; // let the stale run drain completely

    expect(n.state.rows.length, rowsAfterSecond,
        reason: 'late rows from the superseded run must be dropped');
    expect(n.state.report, reportAfterSecond,
        reason: 'and it must not overwrite the newer report');
  });

  test('a superseded run cannot flip isRunning back on the newer one',
      () async {
    final n = InspectNotifier();
    final slow = FakeChameleonDevice.classic1k()
      ..delayPerBlock(const Duration(milliseconds: 5));

    final first = n.start(slow);
    await pumpUntil(() => n.state.rows.isNotEmpty);
    await n.start(FakeChameleonDevice.classic1k());
    await first;

    expect(n.state.isRunning, isFalse);
  });

  test('cancel stops the run and leaves the partial result visible', () async {
    final n = InspectNotifier();
    final slow = FakeChameleonDevice.classic1k()
      ..delayPerBlock(const Duration(milliseconds: 5));

    final f = n.start(slow);
    await pumpUntil(() => n.state.rows.isNotEmpty);
    n.cancel();
    await f;

    expect(n.state.isRunning, isFalse);
    expect(n.state.rows, isNotEmpty,
        reason: 'a partial dump is still worth showing');
    expect(n.state.rows.length, lessThan(64));
  });

  test('starting a new run clears the previous rows', () async {
    final n = InspectNotifier();
    await n.start(FakeChameleonDevice.classic1k());
    expect(n.state.rows.length, 64);
    await n.start(FakeChameleonDevice.ntag215());
    expect(n.state.rows.length, lessThan(64),
        reason: 'NTAG yields fewer units, so stale rows would be visible');
  });

  test('cancelling when nothing runs is harmless', () async {
    final n = InspectNotifier();
    expect(n.cancel, returnsNormally);
    expect(n.state.isRunning, isFalse);
  });
}
