import 'dart:typed_data';

import '../chameleon/cancellation_token.dart';
import '../chameleon/chameleon_device.dart';
import '../mifare/card_layout.dart';
import '../mifare/sak.dart';
import '../nfc/type2.dart';

/// Raw card dump for the inspector. Reads every block (Mifare Classic) or page
/// group (NTAG) and reports each unit the moment it arrives, so the UI renders
/// top-down instead of waiting out ~64 BLE round trips.
///
/// Talks to [ChameleonDevice] directly: a raw dump is not a chunk operation, so
/// the reader/transport layer stays untouched. **Read-only throughout.**
///
/// Port of `webapp/src/inspect/card-dump.ts`.

/// What a unit is, structurally.
enum UnitKind {
  /// Mifare Classic block 0 — UID and manufacturer data.
  manufacturer,

  /// Ordinary data.
  data,

  /// A Mifare Classic sector trailer (keys and access bits). Displayed, never
  /// written.
  trailer,

  /// The NTAG group holding UID, lock bytes and the capability container.
  cc,
}

/// Why a unit has no bytes.
enum UnitFailure {
  /// Wrong key for the sector — a foreign card, not a fault.
  authFailed,

  /// The dump stopped before reaching this unit (card left the field).
  notRead,

  /// Fewer bytes than expected — marginal RF coupling, not content.
  shortRead,
}

/// One block (Classic) or one 4-page READ group (NTAG).
///
/// Carries **either** [bytes] **or** a [failure], never both: a unit that could
/// not be read is reported rather than omitted, because an unreadable sector is
/// itself diagnostic.
class DumpUnit {
  const DumpUnit({
    required this.index,
    required this.kind,
    this.sector,
    this.bytes,
    this.failure,
  });

  /// The starting block (Classic) or page (NTAG).
  final int index;

  /// Sector number on Classic; null on NTAG, which has none.
  final int? sector;

  final UnitKind kind;
  final Uint8List? bytes;
  final UnitFailure? failure;
}

class DumpMeta {
  const DumpMeta({
    required this.sak,
    required this.uid,
    required this.totalUnits,
    this.ntagType,
    this.cardSize,
  });

  final int sak;
  final Uint8List uid;
  final int totalUnits;

  /// The chip when this is an NTAG; null for Mifare Classic.
  final NtagType? ntagType;

  /// The geometry when this is a Mifare Classic; null for NTAG.
  final MifareCardSize? cardSize;

  /// True when this is a Mifare Classic (1K or 4K).
  bool get isClassic => ntagType == null;

  /// The medium, for display.
  Object get medium =>
      ntagType ??
      (cardSize == MifareCardSize.k4
          ? 'mifare-classic-4k'
          : 'mifare-classic-1k');
}

class DumpResult {
  const DumpResult({
    required this.meta,
    required this.units,
    required this.aborted,
    required this.cardLost,
  });

  final DumpMeta meta;
  final List<DumpUnit> units;

  /// The caller cancelled (the dialog was closed).
  final bool aborted;

  /// A non-auth read failure stopped the dump — the card almost certainly left
  /// the field.
  final bool cardLost;
}

class DumpCallbacks {
  const DumpCallbacks({required this.onUnit, this.onMeta});

  /// Fires before the first read, so identity reaches the screen in about a
  /// second rather than after every block has been fetched.
  final void Function(DumpMeta meta)? onMeta;

  final void Function(DumpUnit unit, int done, int total) onUnit;
}

const int _pagesPerRead = 4;

UnitKind _classicKind(int block) {
  if (block == 0) return UnitKind.manufacturer;
  return isSectorTrailer(block) ? UnitKind.trailer : UnitKind.data;
}

/// Dump the card currently in the field.
///
/// Routes on SAK ([classifySak]): 0x08 is a Mifare Classic 1K, 0x18/0x38/0x98 a
/// 4K, 0x00 an NTAG. Anything else
/// raises [UnsupportedTagException] with the SAK in its message — for an
/// inspector that value is the result, so callers must not flatten it.
Future<DumpResult> dumpCard(
  ChameleonDevice dev,
  DumpCallbacks cb, {
  CancellationToken? token,
}) async {
  final tag = await dev.scanTag();
  if (tag == null) {
    throw const TagTimeoutException(
      'No card in the field — hold one on the reader',
    );
  }
  final kind = classifySak(tag.sak);
  final size = cardSizeFor(kind);
  if (size != null) return _dumpClassic(dev, tag, size, cb, token);
  if (kind == TagKind.ntag) return _dumpNtag(dev, tag, cb, token);
  throw UnsupportedTagException(
    'Unsupported tag (SAK 0x${tag.sak.toRadixString(16).padLeft(2, '0')}) — '
    'Mifare Classic 1K/4K and NTAG213/215/216 can be inspected',
  );
}

Future<DumpResult> _dumpClassic(
  ChameleonDevice dev,
  ScannedTag tag,
  MifareCardSize size,
  DumpCallbacks cb,
  CancellationToken? token,
) async {
  final blocks = size == MifareCardSize.k4 ? 256 : 64;
  final meta = DumpMeta(
    sak: tag.sak,
    uid: tag.uid,
    totalUnits: blocks,
    cardSize: size,
  );
  cb.onMeta?.call(meta);

  final units = <DumpUnit>[];
  var aborted = false;
  var cardLost = false;

  for (var block = 0; block < blocks; block++) {
    if (token?.isCancelled ?? false) {
      aborted = true;
      break;
    }
    final sector = sectorOf(block);
    final kind = _classicKind(block);
    DumpUnit unit;
    try {
      final bytes = await dev.readBlock(block, factoryKeyA);
      unit = bytes.length == blockSize
          ? DumpUnit(index: block, sector: sector, kind: kind, bytes: bytes)
          // A short read is marginal RF coupling, never zero-padded content:
          // treating it as data would report a weakly coupled card as holding
          // no chunk, which is false.
          : DumpUnit(
              index: block,
              sector: sector,
              kind: kind,
              failure: UnitFailure.shortRead,
            );
    } on CardAuthException {
      // One custom-keyed sector still leaves a mostly readable card, and that
      // partial view is itself the diagnostic. Report and carry on.
      unit = DumpUnit(
        index: block,
        sector: sector,
        kind: kind,
        failure: UnitFailure.authFailed,
      );
    } catch (_) {
      // Any NON-auth failure means the card has almost certainly left the
      // field. Report this block and every remaining one, then stop rather
      // than grinding through dozens more failing round trips.
      cardLost = true;
      for (var rest = block; rest < blocks; rest++) {
        final u = DumpUnit(
          index: rest,
          sector: sectorOf(rest),
          kind: _classicKind(rest),
          failure: UnitFailure.notRead,
        );
        units.add(u);
        cb.onUnit(u, rest + 1, blocks);
      }
      break;
    }
    units.add(unit);
    cb.onUnit(unit, block + 1, blocks);
  }

  return DumpResult(
    meta: meta,
    units: units,
    aborted: aborted,
    cardLost: cardLost,
  );
}

Future<DumpResult> _dumpNtag(
  ChameleonDevice dev,
  ScannedTag tag,
  DumpCallbacks cb,
  CancellationToken? token,
) async {
  Uint8List version;
  try {
    version = await dev.transceive14a(
      Uint8List.fromList(const [0x60]),
      autoSelect: true,
      appendCrc: true,
      checkResponseCrc: true,
    );
  } catch (_) {
    throw const UnsupportedTagException(
      'Tag does not answer NTAG GET_VERSION',
    );
  }

  final type = detectNtagType(version);
  if (type == null) {
    final storage = version.length > 6
        ? '0x${version[6].toRadixString(16).padLeft(2, '0')}'
        : 'missing';
    throw UnsupportedTagException(
      'Unsupported NTAG (GET_VERSION storage byte $storage unrecognized)',
    );
  }

  final pages = ntagTotalPages(type);
  final groups = (pages / _pagesPerRead).ceil();
  final meta = DumpMeta(
    sak: tag.sak,
    uid: tag.uid,
    totalUnits: groups,
    ntagType: type,
  );
  cb.onMeta?.call(meta);

  final units = <DumpUnit>[];
  var aborted = false;
  var cardLost = false;

  for (var group = 0; group < groups; group++) {
    if (token?.isCancelled ?? false) {
      aborted = true;
      break;
    }
    final startPage = group * _pagesPerRead;
    final pagesHere =
        (_pagesPerRead < pages - startPage) ? _pagesPerRead : pages - startPage;
    final want = pagesHere * 4;
    final isFinal = group == groups - 1;
    // Group 0 holds UID, lock bytes AND the capability container together.
    final kind = group == 0 ? UnitKind.cc : UnitKind.data;

    DumpUnit unit;
    try {
      final resp = await dev.transceive14a(
        Uint8List.fromList([0x30, startPage]),
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: true,
      );
      if (resp.length >= want) {
        unit = DumpUnit(
          index: startPage,
          kind: kind,
          bytes: Uint8List.sublistView(resp, 0, want),
        );
      } else if (isFinal) {
        // A real READ always returns 4 pages and WRAPS to page 0 near the end
        // of memory, so a short response is legitimate on the final group.
        // Anywhere else it means marginal RF coupling. Same symptom, opposite
        // meaning, told apart by position.
        unit = DumpUnit(index: startPage, kind: kind, bytes: resp);
      } else {
        unit = DumpUnit(
          index: startPage,
          kind: kind,
          failure: UnitFailure.shortRead,
        );
      }
    } on CardAuthException {
      unit = DumpUnit(
        index: startPage,
        kind: kind,
        failure: UnitFailure.authFailed,
      );
    } catch (_) {
      cardLost = true;
      for (var rest = group; rest < groups; rest++) {
        final u = DumpUnit(
          index: rest * _pagesPerRead,
          kind: rest == 0 ? UnitKind.cc : UnitKind.data,
          failure: UnitFailure.notRead,
        );
        units.add(u);
        cb.onUnit(u, rest + 1, groups);
      }
      break;
    }
    units.add(unit);
    cb.onUnit(unit, group + 1, groups);
  }

  return DumpResult(
    meta: meta,
    units: units,
    aborted: aborted,
    cardLost: cardLost,
  );
}
