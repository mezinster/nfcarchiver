import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/nfc_provider.dart';

import 'support/fake_card_reader.dart';

/// A scan that ends by itself is reported as stopped, not as an error.
///
/// The restore screen retries every error. Before this, iOS's Cancel arrived as
/// an error too, so the sheet the user had just dismissed came straight back.
void main() {
  late FakeCardReader reader;
  late NfcSessionNotifier notifier;

  setUp(() {
    reader = FakeCardReader(name: 'phone-nfc', supportsRawAccess: false);
    notifier = NfcSessionNotifier(reader);
  });
  tearDown(() => notifier.dispose());

  test('a reader-reported stop becomes NfcSessionStopped', () async {
    await notifier.startReadSession();
    reader.lastOnStopped!(ScanStop.cancelled);
    expect(notifier.state, isA<NfcSessionStopped>());
    expect((notifier.state as NfcSessionStopped).reason, ScanStop.cancelled);
  });

  // Cancelling iOS's write sheet is not a write error: no snackbar, just back.
  test('a stopped write session becomes NfcSessionStopped', () async {
    await notifier.startWriteSession(
      chunk: Chunk(
        archiveId: Uint8List(16),
        totalChunks: 1,
        chunkIndex: 0,
        payload: Uint8List(0),
        crc32: 0,
      ),
      configuredTagType: NfcTagType.ntag216,
    );
    reader.lastWriteOnStopped!(ScanStop.cancelled);
    expect((notifier.state as NfcSessionStopped).reason, ScanStop.cancelled);
  });

  test('errors still arrive as errors', () async {
    await notifier.startReadSession();
    reader.lastOnError!('Session invalidated unexpectedly');
    expect(notifier.state, isA<NfcSessionError>());
  });

  // The screen's retry budget ran out: say so, rather than a spinner forever.
  test('halt ends the scan as failed', () async {
    await notifier.startReadSession();
    notifier.halt();
    expect((notifier.state as NfcSessionStopped).reason, ScanStop.failed);
  });

  test('endTag reaches the reader', () {
    notifier.endTag('Chunk 3 of 12 already scanned', problem: true);
    expect(reader.endedTags, ['problem: Chunk 3 of 12 already scanned']);
  });
}
