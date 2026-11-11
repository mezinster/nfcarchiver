import 'dart:typed_data';

import '../constants/nfar_format.dart';

/// Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K or 4K
/// card.
///
/// Deliberate port of `webapp/src/mifare/card-layout.ts` — same constants, same
/// ordering — so cards written by either app are byte-identical. Change both or
/// neither.
///
/// Layout is raw NFAR-native: serialized chunk bytes run sequentially across the
/// usable blocks (block 0 and every sector trailer skipped), zero-padding the
/// final block. The NFAR header is self-delimiting, so no per-block framing is
/// added.
///
/// 1K: 16 sectors x 4 blocks, 47 usable blocks. 4K: sectors 0-31 have 4 blocks
/// (0-127), sectors 32-39 have 16 blocks (128-255), 215 usable blocks. The 4K
/// list is a strict extension of the 1K list (its first 47 entries are the 1K
/// list), so a chunk that fits 1K is laid out identically on either card.
const int blockSize = 16;

/// Sector trailer = last block of its sector (holds the keys — writing one can
/// brick the card).
bool isSectorTrailer(int block) =>
    block < 128 ? block % 4 == 3 : (block - 128) % 16 == 15;

/// Sector number of a block on a 4K card (identical to 1K for blocks 0-63).
int sectorOf(int block) => block < 128 ? block ~/ 4 : 32 + (block - 128) ~/ 16;

/// First block of [sector] on a 4K card.
int firstBlockOfSector(int sector) =>
    sector < 32 ? sector * 4 : 128 + (sector - 32) * 16;

/// Blocks 0-63 minus block 0 (manufacturer) and every sector trailer.
final List<int> usableBlockIndexes = List.unmodifiable(
  List<int>.generate(64, (b) => b)
      .where((b) => b != 0 && !isSectorTrailer(b))
      .toList(),
);

/// Blocks 0-255 minus block 0 and every sector trailer: 215 blocks.
final List<int> usableBlockIndexes4k = List.unmodifiable(
  List<int>.generate(256, (b) => b)
      .where((b) => b != 0 && !isSectorTrailer(b))
      .toList(),
);

final int cardCapacityBytes = usableBlockIndexes.length * blockSize; // 752
final int cardPayloadSize = cardCapacityBytes - NfarHeaderSize.total; // 720

/// Mifare Classic card geometry this app understands.
enum MifareCardSize {
  k1,
  k4;

  List<int> get usableBlocks =>
      this == MifareCardSize.k4 ? usableBlockIndexes4k : usableBlockIndexes;

  /// 752 (1K) / 3440 (4K).
  int get capacityBytes => usableBlocks.length * blockSize;

  /// Largest chunk payload: capacity minus the NFAR header.
  int get payloadSize => capacityBytes - NfarHeaderSize.total;
}

/// Capacity a write may use: 4K size only when [allow4k] (the user's switch)
/// is on, otherwise the 1K capacity — even on a 4K card.
int writableCapacity(MifareCardSize size, {required bool allow4k}) =>
    size == MifareCardSize.k4 && allow4k
        ? MifareCardSize.k4.capacityBytes
        : MifareCardSize.k1.capacityBytes;

/// A chunk does not fit the Mifare Classic card.
class MifareCapacityException implements Exception {
  MifareCapacityException(this.message);
  final String message;
  @override
  String toString() => 'MifareCapacityException: $message';
}

/// One block-sized write: which block, and the 16 bytes to put there.
class MifareBlockWrite {
  const MifareBlockWrite(this.block, this.data);
  final int block;
  final Uint8List data;
}

/// Split serialized chunk bytes across the usable blocks, zero-padding the last.
List<MifareBlockWrite> chunkToBlocks(
  Uint8List chunkBytes, {
  MifareCardSize size = MifareCardSize.k1,
}) {
  if (chunkBytes.length > size.capacityBytes) {
    final label = size == MifareCardSize.k4 ? '4K' : '1K';
    throw MifareCapacityException(
      'Chunk is ${chunkBytes.length} bytes; a Mifare Classic $label '
      'card holds ${size.capacityBytes}',
    );
  }
  final usable = size.usableBlocks;
  final blockCount = (chunkBytes.length + blockSize - 1) ~/ blockSize;
  final out = <MifareBlockWrite>[];
  for (var i = 0; i < blockCount; i++) {
    final data = Uint8List(blockSize); // zero-filled -> pads the last block
    final start = i * blockSize;
    final end = (start + blockSize).clamp(0, chunkBytes.length);
    data.setAll(0, chunkBytes.sublist(start, end));
    out.add(MifareBlockWrite(usable[i], data));
  }
  return out;
}

/// Whether the first usable block starts an NFAR chunk.
bool firstBlockIsNfar(Uint8List block1) {
  if (block1.length < nfarMagic.length + 1) return false;
  for (var i = 0; i < nfarMagic.length; i++) {
    if (block1[i] != nfarMagic[i]) return false;
  }
  return block1[nfarMagic.length] == nfarVersion;
}

/// Total serialized length declared by an NFAR header.
int nfarTotalLength(
  Uint8List header, {
  MifareCardSize size = MifareCardSize.k1,
}) {
  if (!firstBlockIsNfar(header)) {
    throw const FormatException('Not an NFAR card: magic or version mismatch');
  }
  if (header.length < NfarHeaderSize.total) {
    throw FormatException(
      'Header too short: need ${NfarHeaderSize.total} bytes, '
      'got ${header.length}',
    );
  }
  final payloadSize = ByteData.sublistView(header).getUint16(26); // big-endian
  final total = NfarHeaderSize.total + payloadSize;
  if (total > size.capacityBytes) {
    throw FormatException(
      'Declared length $total exceeds card capacity ${size.capacityBytes}; '
      'card is corrupt or not NFAR',
    );
  }
  return total;
}
