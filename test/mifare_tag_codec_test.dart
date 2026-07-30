import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_block_io.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_tag_codec.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// nfc_manager exposes a const NfcTag constructor explicitly for testing.
// ignore: non_constant_identifier_names
NfcTag FakeTag() => const NfcTag(handle: 'test', data: <String, dynamic>{});

/// In-memory Mifare Classic 1K: 64 blocks of 16 bytes, factory-keyed.
class FakeMifareBlockIO implements MifareBlockIO {
  final Map<int, Uint8List> blocks = {};
  final List<int> authenticatedSectors = [];
  final List<int> writtenBlocks = [];
  bool failAuth = false;

  @override
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA) async {
    if (failAuth) return false;
    authenticatedSectors.add(sectorIndex);
    return true;
  }

  @override
  Future<Uint8List> readBlock(int blockIndex) async =>
      blocks[blockIndex] ?? Uint8List(16);

  @override
  Future<void> writeBlock(int blockIndex, Uint8List data) async {
    writtenBlocks.add(blockIndex);
    blocks[blockIndex] = Uint8List.fromList(data);
  }
}

Chunk makeChunk(int payloadLen) {
  final payload = Uint8List.fromList(
      List.generate(payloadLen, (i) => (i + 3) % 256));
  return Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 4),
    totalChunks: 1,
    chunkIndex: 0,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );
}

void main() {
  test('write then read round-trips a chunk', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);
    final chunk = makeChunk(200);

    await codec.writeChunk(FakeTag(), chunk);
    final read = await codec.readChunk(FakeTag());

    expect(read, isNotNull);
    expect(read!.payload, chunk.payload);
    expect(read.chunkIndex, chunk.chunkIndex);
  });

  test('never writes block 0 or a sector trailer', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);

    await codec.writeChunk(FakeTag(), makeChunk(cardPayloadSize));

    expect(io.writtenBlocks.contains(0), isFalse);
    for (final b in io.writtenBlocks) {
      expect(b % 4 == 3, isFalse, reason: 'wrote sector trailer $b');
    }
  });

  test('authenticates a sector before touching its blocks', () async {
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);
    await codec.writeChunk(FakeTag(), makeChunk(200));
    expect(io.authenticatedSectors, isNotEmpty);
    expect(io.authenticatedSectors.first, 0);
  });

  test('a failed authentication throws rather than writing', () async {
    final io = FakeMifareBlockIO()..failAuth = true;
    final codec = MifareTagCodec((_) => io);
    await expectLater(
      codec.writeChunk(FakeTag(), makeChunk(200)),
      throwsA(isA<MifareAuthException>()),
    );
    expect(io.writtenBlocks, isEmpty);
  });

  test('reads null from a blank card rather than throwing', () async {
    final codec = MifareTagCodec((_) => FakeMifareBlockIO());
    expect(await codec.readChunk(FakeTag()), isNull);
  });

  test('capacity is the raw card capacity', () async {
    final codec = MifareTagCodec((_) => FakeMifareBlockIO());
    expect(await codec.capacityBytes(FakeTag()), cardCapacityBytes);
  });
}
