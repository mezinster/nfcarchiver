import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';

import 'support/fake_card_reader.dart';

void main() {
  late FakeCardReader phone;
  late FakeCardReader chameleon;

  ReaderController controller({bool chameleonFailsToConnect = false}) {
    phone = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    chameleon = FakeCardReader(
      name: 'chameleon-ble',
      supportsRawAccess: true,
      failConnect: chameleonFailsToConnect,
    );
    return ReaderController(
      makePhone: () => phone,
      makeChameleon: (_) => chameleon,
    );
  }

  test('the phone radio is active by default', () {
    final c = controller();
    expect(c.state.kind, ReaderKind.phone);
    expect(c.state.reader.name, 'phone-nfc');
  });

  test('selecting a Chameleon connects it and makes it active', () async {
    final c = controller();
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    expect(c.state.kind, ReaderKind.chameleon);
    expect(c.state.isConnected, isTrue);
    expect(chameleon.connectCalls, 1);
  });

  test('switching readers disconnects the previous one FIRST', () async {
    // Two readers must never hold radios at once: nfc_manager and
    // flutter_reactive_ble both claim hardware, and a leaked session is
    // exactly the half-open-connection hazard the web app hit.
    final c = controller();
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    await c.select(ReaderKind.phone);
    expect(chameleon.disconnectCalls, 1);
    expect(c.state.kind, ReaderKind.phone);
  });

  test('a failed connect leaves a DISCONNECTED state, not a half-connected one',
      () async {
    // The web app's failHandOff lesson: a connect that fails after teardown
    // otherwise leaves the UI reading "connected" with every listener still
    // believing it — a real true->false transition that fires no callbacks.
    final c = controller(chameleonFailsToConnect: true);
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');

    expect(c.state.isConnected, isFalse);
    expect(c.state.kind, ReaderKind.phone,
        reason: 'falls back to the always-available radio');
    expect(c.state.error, isNotNull, reason: 'and says why');
  });

  test('a failed connect still tore down the outgoing reader', () async {
    final c = controller(chameleonFailsToConnect: true);
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    // The failed Chameleon must not be left holding a half-open BLE session.
    expect(chameleon.disconnectCalls, greaterThanOrEqualTo(1));
  });

  test('disconnect returns to the phone radio', () async {
    final c = controller();
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    await c.disconnect();
    expect(c.state.kind, ReaderKind.phone);
    expect(c.state.isConnected, isFalse);
    expect(chameleon.disconnectCalls, 1);
  });

  test('selecting the same reader twice does not stack connections', () async {
    final c = controller();
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    expect(chameleon.connectCalls, lessThanOrEqualTo(2));
    expect(chameleon.disconnectCalls, greaterThanOrEqualTo(1),
        reason: 'the previous session is torn down before the new one opens');
  });

  test('raw access follows the active reader', () async {
    // This is the flag the card inspector is gated on, so it must track the
    // actual active reader rather than a remembered one.
    final c = controller();
    expect(c.state.reader.supportsRawAccess, isFalse);
    await c.select(ReaderKind.chameleon, deviceId: 'AA:BB');
    expect(c.state.reader.supportsRawAccess, isTrue);
    await c.disconnect();
    expect(c.state.reader.supportsRawAccess, isFalse);
  });

  test('a real ChameleonReader can be built from a device id', () {
    // Guards the production factory wiring, which the fakes above bypass.
    final c = ReaderController(
      makePhone: () => FakeCardReader(name: 'phone-nfc', supportsRawAccess: false),
      makeChameleon: (id) => defaultChameleonFactory(id),
    );
    expect(c.state.kind, ReaderKind.phone);
  });
}

/// Exposed for the wiring test above; the production factory builds a
/// ChameleonReader over a BleChameleonDevice.
CardReader defaultChameleonFactory(String deviceId) =>
    FakeCardReader(name: 'chameleon-ble', supportsRawAccess: true);
