import 'dart:typed_data';

import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';

/// An in-memory [ChameleonDevice] for tests.
///
/// Everything above the [ChameleonDevice] seam — the card dump, the Mifare
/// layout, the reader, the inspector — is exercised against this, so only the
/// real BLE implementation needs hardware.
///
/// The knobs (`sectorKeys`, [corruptWrites], [failFromBlock], [removeCard],
/// [overrideSak], [failAnticollision], [delayPerBlock]) exist because each
/// corresponds to a real card situation that has to behave correctly: a foreign
/// card, a failing write-verify, a card pulled mid-dump, an unsupported medium.
class FakeChameleonDevice implements ChameleonDevice {
  FakeChameleonDevice._({
    required this.sak,
    required int blockCount,
    required this.totalPages,
    Map<int, Uint8List>? sectorKeys,
    int seed = 0,
  })  : _sectorKeys = sectorKeys ?? const {},
        _blocks = List<Uint8List>.generate(
          blockCount,
          (b) => Uint8List.fromList(
            List<int>.generate(16, (i) => (seed + b + i) & 0xff),
          ),
        ),
        _pages = List<Uint8List>.generate(
          totalPages,
          (p) => Uint8List.fromList(
            List<int>.generate(4, (i) => (seed + p * 4 + i) & 0xff),
          ),
        );

  /// A Mifare Classic 1K: 64 blocks of 16 bytes, SAK 0x08, 4-byte UID.
  factory FakeChameleonDevice.classic1k({
    Map<int, Uint8List>? sectorKeys,
    int seed = 0,
  }) =>
      FakeChameleonDevice._(
        sak: 0x08,
        blockCount: 64,
        totalPages: 0,
        sectorKeys: sectorKeys,
        seed: seed,
      );

  /// An NTAG215: 135 pages of 4 bytes, SAK 0x00, 7-byte (cascade) UID.
  factory FakeChameleonDevice.ntag215({int seed = 0}) => FakeChameleonDevice._(
        sak: 0x00,
        blockCount: 0,
        totalPages: 135,
        seed: seed,
      );

  int sak;
  final int totalPages;
  final Map<int, Uint8List> _sectorKeys;
  final List<Uint8List> _blocks;
  final List<Uint8List> _pages;

  bool _connected = false;
  bool _cardPresent = true;
  bool _corruptWrites = false;
  bool _failAnticollision = false;
  bool _corruptBcc = false;
  bool _truncateAnticollision = false;
  bool _failGetVersion = false;
  /// NTAG215's storage-size code, as byte 6 of GET_VERSION.
  int _storageByte = 0x11;
  int? _failFromBlock;
  Duration _perBlockDelay = Duration.zero;

  int disconnectCalls = 0;

  // ---- test knobs -----------------------------------------------------------

  void removeCard() => _cardPresent = false;

  void presentCard() => _cardPresent = true;

  /// Writes land, but altered — so a write-then-verify path can be shown to
  /// actually verify rather than assume.
  void corruptWrites() => _corruptWrites = true;

  /// Every block from [block] onward throws [CardReadException], simulating a
  /// card pulled off the reader part-way through a dump.
  void failFromBlock(int block) => _failFromBlock = block;

  void overrideSak(int value) => sak = value;

  void failAnticollision() => _failAnticollision = true;

  /// The card returns a BCC that disagrees with its own UID — a malformed
  /// or UID-writable "magic" card.
  void corruptBcc() => _corruptBcc = true;

  /// Anticollision answers with fewer than the 5 bytes it must return.
  void truncateAnticollision() => _truncateAnticollision = true;

  /// The tag stops answering GET_VERSION — how a non-NTAG Type-2 tag behaves.
  void failGetVersion() => _failGetVersion = true;

  /// Override the GET_VERSION storage byte, so an unrecognised chip can be
  /// tested without inventing a whole new fake.
  void overrideStorageByte(int value) => _storageByte = value;

  /// Place block contents directly, bypassing authentication — for arranging
  /// a card's starting state without going through the write path under test.
  void setBlock(int block, Uint8List data) =>
      _blocks[block] = Uint8List.fromList(data);

  /// Slows each block read so cancellation and superseded-run tests have a run
  /// long enough to interrupt.
  void delayPerBlock(Duration d) => _perBlockDelay = d;

  // ---- ChameleonDevice ------------------------------------------------------

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
  }

  @override
  Future<ScannedTag?> scanTag() async {
    if (!_cardPresent) return null;
    // A 7-byte UID starts with the 0x88 cascade tag in anticollision level 1;
    // a 4-byte UID does not. Card code keys "is this a Classic" off the SAK,
    // but the identity probe keys "is this a cascade" off this byte.
    final uid = sak == 0x08
        ? Uint8List.fromList(const [0xDE, 0xAD, 0xBE, 0xEF])
        : Uint8List.fromList(const [0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]);
    return ScannedTag(
      uid: uid,
      sak: sak,
      atqa: Uint8List.fromList(sak == 0x08 ? const [0x00, 0x04] : const [0x00, 0x44]),
    );
  }

  @override
  Future<Uint8List> transceive14a(
    Uint8List data, {
    bool appendCrc = false,
    bool autoSelect = false,
    bool checkResponseCrc = false,
    bool activateRfField = false,
    bool keepRfField = false,
    int dataBitLength = 0,
  }) async {
    if (!_cardPresent) throw const CardReadException('No card in the field');

    // WUPA (0x52) / REQA (0x26) — 7-bit frames, answered with ATQA.
    if (data.length == 1 && (data[0] == 0x52 || data[0] == 0x26)) {
      if (_failAnticollision) throw const CardReadException('No response to REQA');
      return (await scanTag())!.atqa;
    }

    // Anticollision cascade level 1: 0x93 0x20 -> uid[4] + BCC.
    if (data.length == 2 && data[0] == 0x93 && data[1] == 0x20) {
      if (_failAnticollision) throw const CardReadException('Anticollision failed');
      final tag = (await scanTag())!;
      final cl1 = sak == 0x08
          ? Uint8List.fromList(tag.uid)
          // For a 7-byte UID, CL1 carries 0x88 followed by the first 3 bytes.
          : Uint8List.fromList([0x88, tag.uid[0], tag.uid[1], tag.uid[2]]);
      var bcc = cl1.reduce((a, b) => a ^ b);
      if (_corruptBcc) bcc ^= 0xff;
      final full = Uint8List.fromList([...cl1, bcc]);
      return _truncateAnticollision ? Uint8List.sublistView(full, 0, 3) : full;
    }

    // NTAG GET_VERSION: 0x60 -> 8 bytes, byte 6 being the storage-size code.
    if (data.length == 1 && data[0] == 0x60) {
      if (_failGetVersion) {
        throw const CardReadException('No response to GET_VERSION');
      }
      return Uint8List.fromList(
        [0x00, 0x04, 0x04, 0x02, 0x01, 0x00, _storageByte, 0x03],
      );
    }

    // NTAG WRITE: 0xA2 <page> <4 bytes>.
    if (data.length == 6 && data[0] == 0xA2) {
      final page = data[1];
      if (page >= totalPages) {
        throw const CardReadException('Page out of range');
      }
      _pages[page] = Uint8List.fromList(data.sublist(2, 6));
      return Uint8List(0);
    }

    // NTAG READ: 0x30 <page> -> 4 pages (16 bytes).
    if (data.length == 2 && data[0] == 0x30) {
      final start = data[1];
      if (start >= totalPages) {
        throw const CardReadException('Page out of range');
      }
      final out = <int>[];
      // Deliberately does NOT wrap at the end of memory. A real NTAG READ wraps
      // around to page 0; returning a short slice instead is what makes the
      // "short read is legitimate on the final group only" branch in dumpCard
      // reachable from a test. Making this wrap would silently gut that test.
      for (var p = start; p < start + 4 && p < totalPages; p++) {
        out.addAll(_pages[p]);
      }
      return Uint8List.fromList(out);
    }

    throw CardReadException(
      'FakeChameleonDevice does not implement frame '
      '${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );
  }

  @override
  Future<Uint8List> readBlock(int block, Uint8List key) async {
    _assertClassic();
    if (_perBlockDelay > Duration.zero) await Future<void>.delayed(_perBlockDelay);
    if (!_cardPresent) throw const CardReadException('No card in the field');
    if (_failFromBlock != null && block >= _failFromBlock!) {
      throw CardReadException('Card left the field at block $block');
    }
    _authenticate(block, key);
    return Uint8List.fromList(_blocks[block]);
  }

  @override
  Future<void> writeBlock(int block, Uint8List key, Uint8List data) async {
    _assertClassic();
    if (!_cardPresent) throw const CardReadException('No card in the field');
    if (data.length != 16) {
      throw CardReadException('A block is 16 bytes, got ${data.length}');
    }
    _authenticate(block, key);
    final stored = Uint8List.fromList(data);
    if (_corruptWrites) stored[0] ^= 0xff;
    _blocks[block] = stored;
  }

  // ---- internals ------------------------------------------------------------

  void _assertClassic() {
    if (sak != 0x08) {
      throw const UnsupportedTagException(
        'Block access is Mifare Classic only on this fake',
      );
    }
  }

  void _authenticate(int block, Uint8List key) {
    final expected = _sectorKeys[block ~/ 4] ?? factoryKeyA;
    if (!_bytesEqual(expected, key)) {
      throw CardAuthException('Wrong key for sector ${block ~/ 4}');
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
