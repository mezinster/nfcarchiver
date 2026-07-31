import 'dart:typed_data';

/// A tag seen in the reader's field.
///
/// SAK 0x08 is a Mifare Classic 1K; SAK 0x00 is an NTAG / Type-2 tag. Those two
/// values are how every caller routes between the two media.
class ScannedTag {
  const ScannedTag({
    required this.uid,
    required this.sak,
    required this.atqa,
  });

  final Uint8List uid;
  final int sak;
  final Uint8List atqa;
}

/// The raw-frame capability alone.
///
/// Split out so the identity probe can depend on exactly what it needs — an
/// arbitrary frame exchange — rather than on a whole device. [ChameleonDevice]
/// implements it, so any device satisfies it; Dart's `implements` is nominal,
/// so this supertype has to be declared rather than merely matched.
abstract class RawAntiColl {
  Future<Uint8List> transceive14a(
    Uint8List data, {
    bool appendCrc,
    bool autoSelect,
    bool checkResponseCrc,
    bool activateRfField,
    bool keepRfField,
    int dataBitLength,
  });
}

/// Narrow seam over a Chameleon Ultra.
///
/// Deliberately mirrors `webapp/src/transport/chameleon-device.ts` member for
/// member: the two codebases implement the same protocol, and keeping the seams
/// identical is what makes logic portable between them — the same technique
/// already proven by [card_layout.dart], a port of `card-layout.ts` verified
/// byte-identical by generated fixtures.
///
/// Everything above this interface (the card dump, the Mifare layout, the
/// reader) is testable against a fake, so only the implementation of THIS
/// interface needs real hardware.
abstract class ChameleonDevice implements RawAntiColl {
  bool get isConnected;

  Future<void> connect();

  Future<void> disconnect();

  /// The tag currently in the field, or null if none is present.
  ///
  /// Returning null rather than throwing is load-bearing: polling for a card
  /// is the normal state of a reader waiting for a tap, not an error.
  Future<ScannedTag?> scanTag();

  /// Send a raw ISO 14443-A frame and return the response.
  ///
  /// [dataBitLength] of 0 means "all of the final byte" — the wire protocol
  /// normalises it, so callers pass 0 for whole-byte frames. A 7-bit frame
  /// (WUPA, REQA) passes 7.
  ///
  /// [activateRfField] and [keepRfField] bracket a multi-frame exchange that
  /// must not lose the field between steps: the anticollision probe raises the
  /// field on WUPA, keeps it up, and drops it after cascade level 1. Letting
  /// the field collapse in between would restart the tag and invalidate the
  /// sequence.
  @override
  Future<Uint8List> transceive14a(
    Uint8List data, {
    bool appendCrc = false,
    bool autoSelect = false,
    bool checkResponseCrc = false,
    bool activateRfField = false,
    bool keepRfField = false,
    int dataBitLength = 0,
  });

  /// Read a 16-byte Mifare Classic block, authenticating with key A.
  Future<Uint8List> readBlock(int block, Uint8List key);

  /// Write a 16-byte Mifare Classic block, authenticating with key A.
  Future<void> writeBlock(int block, Uint8List key, Uint8List data);
}

/// The factory key A every blank card ships with. This app only ever uses
/// factory keys and never writes a sector trailer, so a card it has written
/// stays readable by anything else.
final Uint8List factoryKeyA =
    Uint8List.fromList(const [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);

/// Authentication failed for a sector — the card is foreign (a hotel key, a
/// transit card, an office badge), not broken.
///
/// This is a USER situation, not a fault, and callers must never count it
/// toward a retry or abort budget. The web app learned this the hard way: a
/// foreign Mifare Classic fails on authentication rather than detection, so
/// treating auth failure as a hard error aborts a perfectly healthy session.
class CardAuthException implements Exception {
  const CardAuthException(this.message);
  final String message;
  @override
  String toString() => 'CardAuthException: $message';
}

/// A read came back short or malformed — marginal RF coupling, not content.
///
/// Never treat a short read as zero-padded data: that would report a weakly
/// coupled card as "holds no NFAR chunk", which is false and unrecoverable
/// from the user's point of view.
class CardReadException implements Exception {
  const CardReadException(this.message);
  final String message;
  @override
  String toString() => 'CardReadException: $message';
}

/// The tag is neither a Mifare Classic 1K nor an NTAG.
///
/// The message carries the actual SAK value, and callers that surface it must
/// keep it: for the card inspector that value IS the result.
class UnsupportedTagException implements Exception {
  const UnsupportedTagException(this.message);
  final String message;
  @override
  String toString() => 'UnsupportedTagException: $message';
}

/// No tag was presented before the deadline.
class TagTimeoutException implements Exception {
  const TagTimeoutException(this.message);
  final String message;
  @override
  String toString() => 'TagTimeoutException: $message';
}
