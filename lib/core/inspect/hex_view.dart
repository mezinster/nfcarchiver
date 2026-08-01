import 'dart:typed_data';

import '../nfc/type2.dart';
import 'card_dump.dart';
import 'nfar_describe.dart';

/// Text rendering of a card dump: one line per unit for the dialog, plus the
/// whole plain-text report for Copy/Share.
///
/// Kept free of any UI dependency so the exact output is unit-testable — the
/// report is what gets pasted into bug reports, so its content matters, and it
/// is verified byte-for-byte against the TypeScript by
/// `test/inspect_hex_view_test.dart`.
///
/// Port of `webapp/src/inspect/hex-view.ts`.

/// The subset of an anticollision diagnosis this renderer needs.
///
/// Declared here rather than imported from the probe so the formatter stays
/// independent of how identity was obtained. `CardDiagnosis` satisfies it
/// field for field.
class IdentityDiagnosis {
  const IdentityDiagnosis({
    required this.atqa,
    required this.uidCl1,
    required this.bccReturned,
    required this.bccComputed,
    required this.bccValid,
    required this.isCascade,
  });

  final Uint8List atqa;
  final Uint8List uidCl1;
  final int bccReturned;
  final int bccComputed;
  final bool bccValid;
  final bool isCascade;
}

const int _hexWidth = 16 * 3 - 1; // "FF FF ... FF"
const int _atqaBytes = 2;

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Printable ASCII only; everything else becomes '.' so no control character
/// can corrupt a pasted report.
String _ascii(Uint8List b) => String.fromCharCodes(
      b.map((x) => (x >= 0x20 && x <= 0x7e) ? x : 0x2e),
    );

String _byte(int n) => '0x${n.toRadixString(16).padLeft(2, '0')}';

String _u32(int n) => n.toRadixString(16).padLeft(8, '0');

const Map<UnitFailure, String> _failureText = {
  UnitFailure.authFailed: 'auth failed (non-factory key)',
  UnitFailure.notRead: 'not read (card left the field)',
  UnitFailure.shortRead: 'short read (marginal coupling)',
};

String formatUnitRow(DumpUnit u) {
  final label = u.sector == null
      ? 'pg ${u.index.toString().padLeft(3)}'
      : 's${u.sector.toString().padLeft(2)} b${u.index.toString().padLeft(2)}';

  if (u.bytes == null) {
    final why = u.failure != null ? _failureText[u.failure]! : 'unavailable';
    return '$label  ${'── $why ──'.padRight(_hexWidth)}';
  }

  final note = switch (u.kind) {
    UnitKind.trailer => '  ← sector trailer',
    UnitKind.manufacturer => '  ← manufacturer block',
    UnitKind.cc => '  ← UID / lock / capability container',
    UnitKind.data => '',
  };
  return '$label  ${_hex(u.bytes!).padRight(_hexWidth)}  ${_ascii(u.bytes!)}$note';
}

String formatIdentity(DumpMeta meta, IdentityDiagnosis? diag) {
  final medium =
      meta.ntagType == null ? 'Mifare Classic 1K' : ntagLabel(meta.ntagType!);
  final lines = <String>[
    'Medium    $medium (SAK ${_byte(meta.sak)})',
    'UID       ${_hex(meta.uid)}',
  ];

  if (diag == null) {
    lines.add(
      'BCC       anticollision failed — identity unavailable (the dump may still work)',
    );
    return lines.join('\n');
  }

  // ATQA is a fixed 2-byte field (Classic 1K answers 04 00, LSB first). A reader
  // that returns anything else garbled the WUPA frame, and an unlabelled odd
  // value reads as a real card property in a report meant for bug reports — one
  // real tap rendered "ATQA 3F" while the anticollision right after it was clean.
  // The bytes are kept, not dropped: in an inspector the failure is information.
  final atqaNote = diag.atqa.length == _atqaBytes
      ? ''
      : '  ← malformed (expected $_atqaBytes bytes, got ${diag.atqa.length})';
  lines.add('ATQA      ${_hex(diag.atqa)}$atqaNote');
  lines.add('UID (CL1) ${_hex(diag.uidCl1)}');
  lines.add(
    'BCC       returned ${_byte(diag.bccReturned)} · '
    'computed ${_byte(diag.bccComputed)} · '
    '${diag.bccValid ? 'OK' : 'MISMATCH'}',
  );

  // A 7-byte cascade UID is entirely normal on NTAG; it is only a fault when
  // the SAK says this should be a 4-byte Mifare Classic 1K.
  if (diag.isCascade) {
    lines.add(meta.isClassic
        ? 'Verdict   7-byte UID (cascade tag) — not a 4-byte Mifare Classic 1K'
        : 'Verdict   7-byte UID (cascade tag) — normal for NTAG');
  } else if (!diag.bccValid) {
    lines.add(
      'Verdict   malformed block-0 UID (a UID-writable "magic" card); '
      'rewrite block 0 with a correct BCC',
    );
  } else {
    lines.add('Verdict   BCC OK');
  }
  return lines.join('\n');
}

String formatNfar(NfarDescription d) {
  if (d is NfarAbsent) return 'not NFAR: ${d.reason}';
  final p = d as NfarPresent;

  final flagText = [
    p.compressed ? 'GZIP' : 'no compression',
    p.encrypted ? 'AES-256-GCM' : 'no encryption',
  ].join(', ');

  final lines = <String>[
    'magic     NFAR  v${p.version}  flags ${_byte(p.flags)} ($flagText)',
    'archive   ${p.archiveId}',
    'chunk     ${p.chunkIndex + 1} of ${p.totalChunks}',
    'payload   ${p.payloadSize} B    chunk total ${p.totalLength} B',
  ];

  if (p.crcStored == null || p.crcComputed == null) {
    lines.add('CRC32     pending — the dump has not reached the tail yet');
  } else {
    lines.add(
      'CRC32     stored ${_u32(p.crcStored!)} · '
      'computed ${_u32(p.crcComputed!)} · '
      '${p.crcValid! ? 'OK' : 'MISMATCH'}',
    );
  }

  for (final w in p.warnings) {
    lines.add('warning   $w');
  }
  return lines.join('\n');
}

String formatReport(
  DumpMeta meta,
  IdentityDiagnosis? diag,
  NfarDescription nfar,
  List<DumpUnit> units,
) =>
    [
      'NFC Archiver — card inspection',
      '',
      'IDENTITY',
      formatIdentity(meta, diag),
      '',
      'NFAR CHUNK',
      formatNfar(nfar),
      '',
      'RAW (${units.length} of ${meta.totalUnits} units)',
      ...units.map(formatUnitRow),
      '',
    ].join('\n');
