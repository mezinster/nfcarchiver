
import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import '../../../core/mifare/card_layout.dart';

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
  /// Geometry of the card, or null for a Mifare Classic variant this app does
  /// not support (2K, Mini, Plus in SL1).
  MifareCardSize? get cardSize;

  Future<bool> authenticateSector(int sectorIndex, Uint8List keyA);
  Future<Uint8List> readBlock(int blockIndex);
  Future<void> writeBlock(int blockIndex, Uint8List data);
}

/// Real implementation over `nfc_manager`.
class NfcManagerMifareBlockIO implements MifareBlockIO {
  NfcManagerMifareBlockIO(this._mifare);
  final MifareClassicAndroid _mifare;

  @override
  MifareCardSize? get cardSize => switch (_mifare.size) {
        1024 => MifareCardSize.k1,
        4096 => MifareCardSize.k4,
        _ => null,
      };

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
/// when this phone's controller cannot talk CRYPTO1, or when the platform has no
/// Mifare Classic support at all.
///
/// The Android guard is not belt-and-braces. `MifareClassicAndroid.from` casts
/// `tag.data as TagPigeon?`, which THROWS on an iOS tag rather than returning
/// null — and `MifareTagCodec.supports()` calls this for every tap, so an
/// unguarded lookup would break codec selection on the first tag an iPhone sees.
/// (Core NFC has no CRYPTO1, so iOS could never read these cards anyway; the
/// point is to answer "no" instead of throwing.)
MifareBlockIO? mifareIoFor(NfcTag tag) {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  final mifare = MifareClassicAndroid.from(tag);
  if (mifare == null) return null;
  final io = NfcManagerMifareBlockIO(mifare);
  // 2K / Mini / Plus-SL: not offered, so the tag falls through to NDEF.
  return io.cardSize == null ? null : io;
}
