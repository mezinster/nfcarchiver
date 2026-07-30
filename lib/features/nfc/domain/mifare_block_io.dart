import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/platform_tags.dart';

/// Factory key A. Every card this app writes stays factory-keyed, because
/// sector trailers are never written.
final Uint8List factoryKeyA =
    Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

/// Sector authentication failed — the card is not factory-keyed.
class MifareAuthException implements Exception {
  MifareAuthException(this.sectorIndex);
  final int sectorIndex;
  @override
  String toString() =>
      'MifareAuthException: sector $sectorIndex rejected the factory key';
}

/// Narrow block-level access to a Mifare Classic card.
///
/// Exists so the codec is testable without hardware: `nfc_manager`'s
/// `MifareClassic` cannot be constructed in a test.
abstract interface class MifareBlockIO {
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA);
  Future<Uint8List> readBlock(int blockIndex);
  Future<void> writeBlock(int blockIndex, Uint8List data);
}

/// Real implementation over `nfc_manager`.
class NfcManagerMifareBlockIO implements MifareBlockIO {
  NfcManagerMifareBlockIO(this._mifare);
  final MifareClassic _mifare;

  @override
  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA) =>
      _mifare.authenticateSectorWithKeyA(sectorIndex: sectorIndex, key: keyA);

  @override
  Future<Uint8List> readBlock(int blockIndex) =>
      _mifare.readBlock(blockIndex: blockIndex);

  @override
  Future<void> writeBlock(int blockIndex, Uint8List data) =>
      _mifare.writeBlock(blockIndex: blockIndex, data: data);
}

/// Adapter used in production: null when the tag is not a Mifare Classic card,
/// or when this phone's controller cannot talk CRYPTO1.
MifareBlockIO? mifareIoFor(NfcTag tag) {
  final mifare = MifareClassic.from(tag);
  return mifare == null ? null : NfcManagerMifareBlockIO(mifare);
}
