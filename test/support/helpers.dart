import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';

/// A real, valid NFAR chunk built with the production [Chunk] model.
///
/// Built rather than hard-coded so the fixture can never drift from the format
/// it is meant to represent — if the header layout changes, this changes with
/// it and the tests that depend on it stay honest.
Chunk aChunk({int payloadLength = 32, int chunkIndex = 0, int totalChunks = 1}) {
  final payload = Uint8List.fromList(
    List<int>.generate(payloadLength, (i) => (i * 7 + 3) & 0xff),
  );
  return Chunk(
    archiveId: Uint8List.fromList(
      List<int>.generate(16, (i) => (0xA0 + i) & 0xff),
    ),
    totalChunks: totalChunks,
    chunkIndex: chunkIndex,
    payload: payload,
    crc32: payload.crc32,
  );
}

/// The serialized bytes of [aChunk].
Uint8List validChunkBytes({
  int payloadLength = 32,
  int chunkIndex = 0,
  int totalChunks = 1,
}) =>
    aChunk(
      payloadLength: payloadLength,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
    ).toBytes();

/// Yield to the event loop once.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Poll until [cond] holds, failing the test on timeout.
///
/// Fails loudly rather than hanging: a stuck poll loop should surface as a
/// named test failure, not as a suite that never finishes.
Future<void> pumpUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil timed out after ${timeout.inMilliseconds}ms');
    }
    await Future<void>.delayed(step);
  }
}
