import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';

/// Emits the exact block image the Dart layout produces, so the TypeScript
/// side can assert byte equality. Run: dart run tool/generate_mifare_fixtures.dart
void main() {
  const payloadLength = 300;
  final payload =
      Uint8List.fromList(List.generate(payloadLength, (i) => (i + 3) % 256));
  final chunk = Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 4),
    totalChunks: 1,
    chunkIndex: 0,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );

  final blocks = chunkToBlocks(chunk.toBytes())
      .map((w) => {
            'block': w.block,
            'hex': w.data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          })
      .toList();

  final out = File('webapp/test/fixtures/mifare-card.json');
  out.createSync(recursive: true);
  out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
    'payloadLength': payloadLength,
    'blocks': blocks,
  }));
  stdout.writeln('wrote ${out.path} with ${blocks.length} blocks');
}
