import 'dart:typed_data';

import '../chameleon/chameleon_device.dart';

/// What anticollision reveals about a card's identity.
class CardDiagnosis {
  const CardDiagnosis({
    required this.atqa,
    required this.uidCl1,
    required this.bccReturned,
    required this.bccComputed,
    required this.bccValid,
    required this.isCascade,
  });

  /// Answer To reQuest type A, 2 bytes.
  final Uint8List atqa;

  /// The 4 UID bytes returned in cascade level 1. Starts with 0x88 for a
  /// 7-byte UID, in which case these are not the whole UID.
  final Uint8List uidCl1;

  /// The BCC the card actually returned.
  final int bccReturned;

  /// The BCC computed from [uidCl1].
  final int bccComputed;

  /// False means the card's own checksum disagrees with its UID — a malformed
  /// or UID-writable "magic" card.
  final bool bccValid;

  /// True when [uidCl1] begins with the 0x88 cascade tag, i.e. a 7-byte UID.
  final bool isCascade;
}

/// Probe a card's identity with a raw anticollision exchange.
///
/// This is the check that catches cards which lie about themselves: a
/// self-inconsistent BCC is reported rather than raised, because for an
/// inspector that inconsistency is the finding.
///
/// Callers should treat a thrown failure as **advisory** — [ChameleonDevice]'s
/// block reads perform their own select, so a card that refuses anticollision
/// can still be dumped. `runInspection` catches and continues.
///
/// Port of `webapp/app/diagnostics.ts`.
Future<CardDiagnosis> diagnoseCard(RawAntiColl dev) async {
  // 7-bit WUPA (0x52) wakes any tag in the field and returns its ATQA. The
  // field is raised here and held, because the anticollision that follows is
  // part of the same exchange.
  final atqa = await dev.transceive14a(
    Uint8List.fromList(const [0x52]),
    dataBitLength: 7,
    activateRfField: true,
    keepRfField: true,
  );

  // Anticollision cascade level 1 (0x93 0x20) returns 4 UID bytes plus one BCC
  // byte, with no CRC.
  final ac = await dev.transceive14a(
    Uint8List.fromList(const [0x93, 0x20]),
  );
  if (ac.length < 5) {
    throw CardReadException(
      'Anticollision returned ${ac.length} bytes, expected 5 (UID + BCC)',
    );
  }

  final uidCl1 = Uint8List.sublistView(ac, 0, 4);
  final bccReturned = ac[4];
  final bccComputed =
      (uidCl1[0] ^ uidCl1[1] ^ uidCl1[2] ^ uidCl1[3]) & 0xff;

  return CardDiagnosis(
    atqa: atqa,
    uidCl1: uidCl1,
    bccReturned: bccReturned,
    bccComputed: bccComputed,
    bccValid: bccReturned == bccComputed,
    isCascade: uidCl1[0] == 0x88,
  );
}
