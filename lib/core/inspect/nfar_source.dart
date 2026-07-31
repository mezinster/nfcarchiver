import 'dart:typed_data';

import '../mifare/card_layout.dart';
import '../nfc/ndef_bytes.dart';
import '../nfc/type2.dart';
import 'card_dump.dart';

/// Where the inspector's NFAR bytes came from — or precisely why there are none.
///
/// The Classic path always yields raw bytes. The NTAG path can fail two
/// structurally different ways, and collapsing them into one message would be
/// misinformation: a TLV that has not fully arrived yet is not the same fact as
/// a complete, valid NDEF record whose MIME type simply is not ours.
sealed class NfarSource {
  const NfarSource();
}

class SourceBytes extends NfarSource {
  const SourceBytes(this.bytes);
  final Uint8List bytes;
}

/// No complete NDEF TLV in the pages read so far — may simply be mid-dump.
class SourceNoEnvelope extends NfarSource {
  const SourceNoEnvelope(this.reason);
  final String reason;
}

/// A complete, valid NDEF record that belongs to someone else.
class SourceForeign extends NfarSource {
  const SourceForeign(this.reason);
  final String reason;
}

/// Blocks that should hold the chunk were read, but came back unreadable.
class SourceUnreadable extends NfarSource {
  const SourceUnreadable(this.reason);
  final String reason;
}

/// Rebuild the NFAR chunk stream from the units seen so far, so the header can
/// be described while the dump is still running.
///
/// The two media store a chunk differently and this is easy to get wrong:
/// Classic holds the raw chunk across the usable blocks (block 0 and every
/// sector trailer skipped), whereas NTAG wraps it in a Type-2 TLV around an
/// NDEF MIME record starting at page 4. **Concatenating raw NTAG pages yields
/// the TLV header, not NFAR magic**, so without the unwrap below an NTAG card
/// would always be reported as "not NFAR".
///
/// Port of `nfarBytesSoFar` in `webapp/app/ui/inspect-orchestrator.ts`.
NfarSource nfarBytesSoFar(
  List<DumpUnit> units, {
  required bool isClassic,
}) {
  final wanted = isClassic
      ? units.where((u) => usableBlockIndexes.contains(u.index)).toList()
      : units.where((u) => u.index >= ndefStartPage).toList();

  final parts = <Uint8List>[];
  for (final u in wanted) {
    // A gap makes everything after it meaningless — the stream would silently
    // splice unrelated bytes together and describe a chunk that never existed.
    if (u.bytes == null) break;
    parts.add(u.bytes!);
  }

  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final raw = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    raw.setRange(off, off + p.length, p);
    off += p.length;
  }

  if (isClassic) {
    // Reading nothing when usable blocks WERE seen means the first of them
    // failed — most often a non-factory key on sector 0. describeNfar would
    // call that "0 bytes read", which is false: the dump did read blocks, they
    // just came back unreadable.
    if (total == 0 && wanted.isNotEmpty) {
      return const SourceUnreadable(
        'the blocks holding the chunk could not be read (non-factory key?)',
      );
    }
    return SourceBytes(raw);
  }

  Uint8List ndef;
  try {
    ndef = readType2Ndef(raw);
  } on NdefFormatException {
    // Mid-dump this fires until enough of the TLV has arrived, and it fires
    // just the same at the end for a tag with no NDEF at all. Both are
    // accurately described this way, so it needs no knowledge of whether the
    // dump has finished.
    return const SourceNoEnvelope(
      'no complete NDEF TLV in the pages read so far',
    );
  }

  try {
    return SourceBytes(decodeNdefMime(ndef));
  } on NdefFormatException {
    return const SourceForeign(
      'valid NDEF record, but not an NFAR chunk (different MIME type)',
    );
  }
}
