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
NfcTag FakeTag() => const NfcTag(data: <String, dynamic>{});

/// In-memory Mifare Classic 1K: 64 blocks of 16 bytes, factory-keyed.
class FakeMifareBlockIO implements MifareBlockIO {
  final Map<int, Uint8List> blocks = {};
  final List<int> authenticatedSectors = [];
  final List<int> writtenBlocks = [];
  bool failAuth = false;
  bool corruptWrites = false;

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
    if (corruptWrites) {
      // Simulate a card that silently didn't take the write: store something
      // other than what was given, so the codec's read-back check fires.
      final stored = Uint8List.fromList(data);
      stored[0] = stored[0] ^ 0xFF;
      blocks[blockIndex] = stored;
    } else {
      blocks[blockIndex] = Uint8List.fromList(data);
    }
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

/// Raw 32-byte NFAR header spanning the first two usable blocks: valid magic
/// + version, the given big-endian declared payload size at offset 26, and
/// every other field left zero. Used to seed a card directly (bypassing
/// writeChunk) so a test can control exactly what the declared length says
/// without needing a real, fully-formed Chunk.
Uint8List _rawHeader(int declaredPayloadSize) {
  final header = Uint8List(32);
  header[0] = 0x4E; // 'N'
  header[1] = 0x46; // 'F'
  header[2] = 0x41; // 'A'
  header[3] = 0x52; // 'R'
  header[4] = 0x01; // version
  header[26] = (declaredPayloadSize >> 8) & 0xFF;
  header[27] = declaredPayloadSize & 0xFF;
  return header;
}

/// Seeds the first two usable blocks (where the NFAR header lives) directly.
void _seedHeaderBlocks(FakeMifareBlockIO io, Uint8List header32) {
  io.blocks[usableBlockIndexes[0]] = Uint8List.sublistView(header32, 0, 16);
  io.blocks[usableBlockIndexes[1]] = Uint8List.sublistView(header32, 16, 32);
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

  test(
      'a card declaring a length past capacity reads null rather than '
      'throwing', () async {
    // Valid magic + version (passes firstBlockIsNfar), but a declared
    // payload size of 0xFFFF pushes nfarTotalLength's total well past
    // cardCapacityBytes, so nfarTotalLength itself throws FormatException.
    // readChunk must catch that and return null instead of letting it
    // escape the restore scan loop.
    final io = FakeMifareBlockIO();
    _seedHeaderBlocks(io, _rawHeader(0xFFFF));
    final codec = MifareTagCodec((_) => io);

    expect(await codec.readChunk(FakeTag()), isNull);
  });

  test(
      'a valid header with a CRC that does not match its payload still '
      'round-trips (CRC is not verified at this layer)', () async {
    // This test exists to justify (and pin) why readChunk's second
    // try/catch target -- Chunk.fromBytes -- is guarded even though no
    // malformed-but-nfarTotalLength-passing input can currently reach it:
    // Chunk.fromBytes performs no CRC check, and its own length guard
    // (NfarHeaderOffset.payload + NfarHeaderSize.crc32) is definitionally
    // equal to nfarTotalLength's (NfarHeaderSize.total), so once
    // nfarTotalLength has accepted a header, Chunk.fromBytes cannot reject
    // the same bytes. Verified here: a chunk with a deliberately wrong CRC
    // still comes back non-null, with the bad CRC preserved as-is -- CRC
    // verification is ChunkerService.assembleChunks' job, not readChunk's.
    // The catch around Chunk.fromBytes remains valid defensive code (e.g.
    // against a future CRC check being added there, or the two length
    // formulas drifting apart), it is just not exercisable today.
    final payload = Uint8List.fromList(List.generate(50, (i) => i));
    final corrupted = Chunk(
      archiveId: Uint8List(16)..fillRange(0, 16, 4),
      totalChunks: 1,
      chunkIndex: 0,
      payload: payload,
      crc32: 0xDEADBEEF, // does not match payload
    );
    final io = FakeMifareBlockIO();
    final codec = MifareTagCodec((_) => io);

    await codec.writeChunk(FakeTag(), corrupted);
    final read = await codec.readChunk(FakeTag());

    expect(read, isNotNull);
    expect(read!.crc32, 0xDEADBEEF);
  });

  test('a read-back mismatch throws rather than silently succeeding',
      () async {
    final io = FakeMifareBlockIO()..corruptWrites = true;
    final codec = MifareTagCodec((_) => io);

    await expectLater(
      codec.writeChunk(FakeTag(), makeChunk(200)),
      throwsA(isA<StateError>()),
    );
  });
}
