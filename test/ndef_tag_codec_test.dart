import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_io.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_tag_codec.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// nfc_manager exposes a const NfcTag constructor explicitly for testing.
NfcTag fakeTag() => const NfcTag(handle: 'test', data: <String, dynamic>{});

/// In-memory NDEF tag. Mirrors `FakeMifareBlockIO`: the codec's real logic runs
/// against it, so everything above the platform boundary is testable without a
/// card. `Ndef` itself cannot be constructed in a test, which is the whole
/// reason this seam exists.
class FakeNdefIO implements NdefIO {
  FakeNdefIO({this.maxSize = 868, this.isWritable = true, this.stored});

  @override
  final int maxSize;
  @override
  final bool isWritable;

  NdefMessage? stored;
  final List<NdefMessage> writes = [];

  @override
  Future<NdefMessage> read() async => stored ?? NdefMessage([]);

  @override
  Future<void> write(NdefMessage message) async {
    writes.add(message);
    stored = message;
  }
}

Chunk makeChunk(int payloadLen) {
  final payload =
      Uint8List.fromList(List.generate(payloadLen, (i) => (i + 3) % 256));
  return Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 7),
    totalChunks: 2,
    chunkIndex: 1,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );
}

void main() {
  test('writeChunk refuses a tag that is not writable', () async {
    final io = FakeNdefIO(isWritable: false);
    final codec = NdefTagCodec((_) => io);

    await expectLater(
      () => codec.writeChunk(fakeTag(), makeChunk(64)),
      throwsStateError,
    );
    expect(io.writes, isEmpty, reason: 'nothing may be written to a locked tag');
  });

  test('write then read round-trips a chunk', () async {
    final io = FakeNdefIO();
    final codec = NdefTagCodec((_) => io);
    final chunk = makeChunk(120);

    await codec.writeChunk(fakeTag(), chunk);
    final read = await codec.readChunk(fakeTag());

    expect(read, isNotNull);
    expect(read!.payload, chunk.payload);
    expect(read.chunkIndex, chunk.chunkIndex);
    expect(read.totalChunks, chunk.totalChunks);
    expect(read.archiveId, chunk.archiveId);
  });

  test('readChunk returns null when the tag holds no NFAR record', () async {
    final io = FakeNdefIO(stored: NdefMessage([]));
    final codec = NdefTagCodec((_) => io);

    expect(await codec.readChunk(fakeTag()), isNull);
  });

  test('does not claim a tag that carries no NDEF technology', () {
    expect(NdefTagCodec((_) => null).supports(fakeTag()), isFalse);
  });

  test('claims a tag that carries NDEF', () {
    expect(NdefTagCodec((_) => FakeNdefIO()).supports(fakeTag()), isTrue);
  });

  test('capacityBytes is derived from the tag NDEF message capacity', () async {
    // NTAG215's 496-byte message area. The codec reports *chunk* bytes, so the
    // answer must be smaller than maxSize — the record overhead comes off.
    final codec = NdefTagCodec((_) => FakeNdefIO(maxSize: 496));

    final capacity = await codec.capacityBytes(fakeTag());

    expect(capacity, lessThan(496));
    expect(capacity, greaterThan(0));
  });
}
