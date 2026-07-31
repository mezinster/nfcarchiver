import 'dart:typed_data';

import '../constants/nfar_format.dart';
import '../services/checksum_service.dart';

/// What an inspector can say about a candidate NFAR chunk.
sealed class NfarDescription {
  const NfarDescription();
}

/// No usable chunk here, and precisely why.
///
/// The reason is deliberately specific — "magic mismatch: got DE AD BE EF" is
/// useful, "not an NFAR chunk" is not.
class NfarAbsent extends NfarDescription {
  const NfarAbsent(this.reason);
  final String reason;
}

/// A chunk header was found and parsed, whether or not it is entirely sound.
class NfarPresent extends NfarDescription {
  const NfarPresent({
    required this.version,
    required this.flags,
    required this.compressed,
    required this.encrypted,
    required this.archiveId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.payloadSize,
    required this.totalLength,
    required this.crcStored,
    required this.crcComputed,
    required this.crcValid,
    required this.warnings,
  });

  final int version;
  final int flags;
  final bool compressed;
  final bool encrypted;
  final String archiveId;
  final int chunkIndex;
  final int totalChunks;
  final int payloadSize;

  /// Header + payload + CRC, as declared by the header.
  final int totalLength;

  /// Null when the payload has not fully arrived — there is then nothing to
  /// compare, which is NOT the same as a mismatch.
  final int? crcStored;
  final int? crcComputed;
  final bool? crcValid;

  /// Non-fatal oddities worth showing: an over-capacity declared length,
  /// unknown flag bits, an out-of-range chunk index.
  final List<String> warnings;
}

String _spaced(Uint8List b) => b
    .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

String _formatArchiveId(Uint8List id) {
  final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

/// Describe whatever NFAR structure [data] contains.
///
/// **Deliberately more tolerant than [Chunk.fromBytes].** Where the production
/// decoder throws, this reports: in an inspector the malformed header is the
/// information the user came for, so a failure must be described, never raised.
/// Do not "simplify" this to delegate to the production decoder — that would
/// silently destroy the feature.
///
/// [capacityBytes] is the tag's usable capacity when it is known (Mifare
/// Classic has a fixed one). On NTAG the chunk arrives inside an NDEF envelope
/// whose own TLV length already bounds it, so callers pass null rather than
/// guessing a capacity they have not read.
NfarDescription describeNfar(Uint8List data, {int? capacityBytes}) {
  const headerPrefix = NfarHeaderOffset.payload; // 28: header without the CRC
  const totalOverhead = NfarHeaderSize.total; // 32: header + trailing CRC

  final minToJudge = nfarMagic.length + 1;
  if (data.length < minToJudge) {
    return NfarAbsent(
      'only ${data.length} bytes read; need at least $minToJudge to identify a chunk',
    );
  }

  for (var i = 0; i < nfarMagic.length; i++) {
    if (data[i] != nfarMagic[i]) {
      return NfarAbsent(
        'magic mismatch: got ${_spaced(Uint8List.sublistView(data, 0, nfarMagic.length))}, '
        'expected 4E 46 41 52 ("NFAR")',
      );
    }
  }

  final version = data[NfarHeaderOffset.version];
  if (version != nfarVersion) {
    return NfarAbsent('unsupported version $version (expected $nfarVersion)');
  }

  if (data.length < headerPrefix) {
    return NfarAbsent(
      'header incomplete: ${data.length} of $headerPrefix bytes read',
    );
  }

  final view = ByteData.sublistView(data);
  final flags = data[NfarHeaderOffset.flags];
  final totalChunks = view.getUint16(NfarHeaderOffset.totalChunks);
  final chunkIndex = view.getUint16(NfarHeaderOffset.chunkIndex);
  final payloadSize = view.getUint16(NfarHeaderOffset.payloadSize);
  final totalLength = totalOverhead + payloadSize;

  final warnings = <String>[];
  if (capacityBytes != null && totalLength > capacityBytes) {
    warnings.add(
      "declared length $totalLength B exceeds the tag's $capacityBytes B capacity",
    );
  }
  if ((flags & ~(NfarFlags.compressed | NfarFlags.encrypted)) != 0) {
    warnings.add(
      'unknown flag bits set: 0x${flags.toRadixString(16).padLeft(2, '0')}',
    );
  }
  if (totalChunks > 0 && chunkIndex >= totalChunks) {
    warnings.add(
      'chunk index $chunkIndex is out of range for $totalChunks chunk(s)',
    );
  }

  int? crcStored;
  int? crcComputed;
  // Only when the declared payload has fully arrived. Comparing against a
  // partial payload would manufacture a mismatch out of an incomplete read.
  if (data.length >= totalLength) {
    crcStored = view.getUint32(headerPrefix + payloadSize);
    crcComputed = ChecksumService.instance.calculate(
      Uint8List.sublistView(data, headerPrefix, headerPrefix + payloadSize),
    );
  }

  return NfarPresent(
    version: version,
    flags: flags,
    compressed: NfarFlags.isCompressed(flags),
    encrypted: NfarFlags.isEncrypted(flags),
    archiveId: _formatArchiveId(
      Uint8List.sublistView(data, NfarHeaderOffset.archiveId, NfarHeaderOffset.totalChunks),
    ),
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    payloadSize: payloadSize,
    totalLength: totalLength,
    crcStored: crcStored,
    crcComputed: crcComputed,
    crcValid: crcStored == null ? null : crcStored == crcComputed,
    warnings: warnings,
  );
}
