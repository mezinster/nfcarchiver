/// Generates interop fixtures for the webapp TS core using the app's own
/// production services. Run from the repo root:
///   dart run tool/generate_web_fixtures.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/core/services/chunker_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final original = Uint8List.fromList(List.generate(200, (i) => i % 251));
  // Deliberately padded: proves both sides trim before key derivation.
  const password = '  interop-password  ';

  final result = ChunkerService.instance.createChunksWithSize(
    data: original,
    payloadSize: 64,
  );
  final encrypted = EncryptionService.instance.encrypt(original, password);
  final gzipped = CompressionService.instance.compress(original);
  final crc = ChecksumService.instance.calculate(original);

  final json = const JsonEncoder.withIndent('  ').convert({
    'payloadSize': 64,
    'original': hexOf(original),
    'chunks': result.chunks.map((c) => hexOf(c.toBytes())).toList(),
    'password': password,
    'encrypted': hexOf(encrypted),
    'gzipped': hexOf(gzipped),
    'crc32OfOriginal': crc,
  });

  final out = File('webapp/test/fixtures/dart_generated.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$json\n');
  stdout.writeln('Wrote ${out.path}');
}
