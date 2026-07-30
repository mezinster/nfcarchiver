import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/mifare/card_layout.dart';
import '../../../core/models/chunk.dart';
import 'mifare_block_io.dart';
import 'tag_codec.dart';

/// Mifare Classic 1K holding a raw NFAR chunk across its usable data blocks.
///
/// Byte-compatible with the web app: same block set, same ordering, same
/// zero-padding. Sector trailers are never written, so cards stay factory-keyed
/// and re-writable.
class MifareTagCodec implements TagCodec {
  MifareTagCodec(this._ioFor);

  final MifareBlockIO? Function(NfcTag tag) _ioFor;

  @override
  String get name => 'Mifare Classic';

  @override
  bool supports(NfcTag tag) => _ioFor(tag) != null;

  @override
  Future<int> capacityBytes(NfcTag tag) async => cardCapacityBytes;

  int _sectorOf(int block) => block ~/ 4;

  /// Authenticate a sector once, then keep using it until the sector changes.
  Future<void> _ensureSector(
      MifareBlockIO io, int block, int? currentSector) async {
    final sector = _sectorOf(block);
    if (sector == currentSector) return;
    if (!await io.authenticateSector(sector, factoryKeyA)) {
      throw MifareAuthException(sector);
    }
  }

  @override
  Future<Chunk?> readChunk(NfcTag tag) async {
    final io = _ioFor(tag);
    if (io == null) return null;

    int? sector;
    final first = usableBlockIndexes.first;
    await _ensureSector(io, first, sector);
    sector = _sectorOf(first);
    final head = await io.readBlock(first);
    if (!firstBlockIsNfar(head)) return null;

    // Read enough blocks to cover the declared length. The header spans the
    // first two usable blocks, so read the second before trusting the length.
    // `nfarTotalLength` and `Chunk.fromBytes` both throw `FormatException` on
    // malformed data; a card whose first block happens to pass the magic/
    // version check but whose later bytes are garbage (or not NFAR at all)
    // must still come back as "not one of ours" rather than blow up the
    // caller's scan loop, so those exceptions are caught here and folded
    // into a null result rather than allowed to escape.
    final bytes = BytesBuilder()..add(head);
    for (final block in usableBlockIndexes.skip(1)) {
      await _ensureSector(io, block, sector);
      sector = _sectorOf(block);
      bytes.add(await io.readBlock(block));
      if (bytes.length >= 32) {
        try {
          final total = nfarTotalLength(Uint8List.fromList(bytes.toBytes()));
          if (bytes.length >= total) {
            return Chunk.fromBytes(
                Uint8List.fromList(bytes.toBytes().sublist(0, total)));
          }
        } on FormatException {
          return null;
        }
      }
    }
    return null;
  }

  @override
  Future<void> writeChunk(NfcTag tag, Chunk chunk) async {
    final io = _ioFor(tag);
    if (io == null) {
      throw StateError('Tag is not a Mifare Classic card');
    }
    final writes = chunkToBlocks(chunk.toBytes());

    // Authenticate every sector we are about to touch BEFORE writing anything,
    // so a non-factory-keyed card fails without leaving a half-written chunk.
    final sectors = writes.map((w) => _sectorOf(w.block)).toSet();
    for (final sector in sectors) {
      if (!await io.authenticateSector(sector, factoryKeyA)) {
        throw MifareAuthException(sector);
      }
    }

    int? sector;
    for (final write in writes) {
      await _ensureSector(io, write.block, sector);
      sector = _sectorOf(write.block);
      await io.writeBlock(write.block, write.data);
      final back = await io.readBlock(write.block);
      if (!_bytesEqual(back, write.data)) {
        throw StateError('Read-back mismatch on block ${write.block}');
      }
    }
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
