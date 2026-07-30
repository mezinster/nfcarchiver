import 'dart:typed_data';

import '../constants/nfar_format.dart';

/// Maps one NFAR chunk onto the usable data blocks of a Mifare Classic 1K card.
///
/// Deliberate port of `webapp/src/mifare/card-layout.ts` — same constants, same
/// ordering — so cards written by either app are byte-identical. Change both or
/// neither.
///
/// Layout is raw NFAR-native: serialized chunk bytes run sequentially across the
/// 47 usable blocks (block 0 and every sector trailer skipped), zero-padding the
/// final block. The NFAR header is self-delimiting, so no per-block framing is
/// added.
const int blockSize = 16;

/// Blocks 0-63 minus block 0 (manufacturer) and every `b % 4 == 3` (sector
/// trailer, holds the keys — writing one can brick the card).
final List<int> usableBlockIndexes = List.unmodifiable(
  List<int>.generate(64, (b) => b).where((b) => b != 0 && b % 4 != 3).toList(),
);

final int cardCapacityBytes = usableBlockIndexes.length * blockSize; // 752
final int cardPayloadSize = cardCapacityBytes - NfarHeaderSize.total; // 720

/// A chunk does not fit a Mifare Classic 1K card.
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
List<MifareBlockWrite> chunkToBlocks(Uint8List chunkBytes) {
  if (chunkBytes.length > cardCapacityBytes) {
    throw MifareCapacityException(
      'Chunk is ${chunkBytes.length} bytes; a Mifare Classic 1K card holds '
      '$cardCapacityBytes',
    );
  }
  final blockCount = (chunkBytes.length + blockSize - 1) ~/ blockSize;
  final out = <MifareBlockWrite>[];
  for (var i = 0; i < blockCount; i++) {
    final data = Uint8List(blockSize); // zero-filled -> pads the last block
    final start = i * blockSize;
    final end = (start + blockSize).clamp(0, chunkBytes.length);
    data.setAll(0, chunkBytes.sublist(start, end));
    out.add(MifareBlockWrite(usableBlockIndexes[i], data));
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
int nfarTotalLength(Uint8List header) {
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
  return NfarHeaderSize.total + payloadSize;
}
