import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_repository.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';

import 'support/fake_card_reader.dart';

/// The session notifier turns every way a reader can fail into a typed
/// [NfcFailure]; the exception itself goes to the log, never to the state.
void main() {
  setUp(() => log.clear());
  tearDown(() => log.clear());

  test('NfcSessionNotifier maps an unavailable reader to nfcUnavailable',
      () async {
    final reader = FakeCardReader(
        name: 'phone-nfc', supportsRawAccess: false, available: false);
    final notifier = NfcSessionNotifier(reader);
    addTearDown(notifier.dispose);

    await notifier.startReadSession();

    final state = notifier.state;
    expect(state, isA<NfcSessionError>());
    expect((state as NfcSessionError).failure.kind,
        NfcFailureKind.nfcUnavailable);
  });

  test('a thrown startReadSession is reported and becomes unknown', () async {
    final reader = FakeCardReader(
        name: 'phone-nfc', supportsRawAccess: false)
      ..readSessionError = StateError('boom');
    final notifier = NfcSessionNotifier(reader);
    addTearDown(notifier.dispose);

    await notifier.startReadSession();

    final state = notifier.state;
    expect(state, isA<NfcSessionError>());
    expect((state as NfcSessionError).failure.kind, NfcFailureKind.unknown);
    final reported = log
        .snapshot()
        .where((e) => e.level == LogLevel.error && (e.detail ?? '').contains('boom'));
    expect(reported, hasLength(1));
  });

  test('a reader-reported failure reaches the state unchanged', () async {
    final reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    final notifier = NfcSessionNotifier(reader);
    addTearDown(notifier.dispose);

    await notifier.startReadSession();
    reader.lastOnError!(const NfcFailure(NfcFailureKind.noArchiveData));

    expect((notifier.state as NfcSessionError).failure.kind,
        NfcFailureKind.noArchiveData);
  });

  test("iOS's sheet shows fixed English, never exception text", () {
    expect(iosSheetText(const NfcFailure(NfcFailureKind.noArchiveData)),
        'No NFC Archiver data on this tag');
    expect(iosSheetText(const NfcFailure(NfcFailureKind.readFailed)),
        "Couldn't read this tag");
    expect(
        iosSheetText(const NfcFailure(NfcFailureKind.writeFailed),
            writing: true),
        "Couldn't write this tag");
  });
}
