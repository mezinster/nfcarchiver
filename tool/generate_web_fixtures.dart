/// Generates interop fixtures for the webapp TS core using the app's own
/// production services. Run from the repo root:
///   dart run tool/generate_web_fixtures.dart
///
/// Output is randomized (archive ID, salt, IV), so committed fixtures will
/// not match a fresh run byte-for-byte — regenerating always produces a
/// diff; that is expected.
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

Uint8List prependFilename(Uint8List data, String fileName) {
  final nameBytes = utf8.encode(fileName);
  final name = nameBytes.length > 255 ? nameBytes.sublist(0, 255) : nameBytes;
  final out = Uint8List(2 + name.length + data.length);
  out[0] = (name.length >> 8) & 0xFF;
  out[1] = name.length & 0xFF;
  out.setRange(2, 2 + name.length, name);
  out.setRange(2 + name.length, out.length, data);
  return out;
}

void main() {
  final original = Uint8List.fromList(List.generate(200, (i) => i % 251));
  // Deliberately padded: proves both sides trim before key derivation.
  const password = '  interop-password  ';
  // Compressible payload: proves gzip interop over real Huffman/LZ77 data,
  // not just a stored (uncompressed) deflate block.
  final textPayload = Uint8List.fromList(
    utf8.encode('nfar gzip interop ' * 200),
  );

  final result = ChunkerService.instance.createChunksWithSize(
    data: original,
    payloadSize: 64,
  );
  final encrypted = EncryptionService.instance.encrypt(original, password);
  final gzipped = CompressionService.instance.compress(original);
  final crc = ChecksumService.instance.calculate(original);

  const wrappedFileName = 'my report.txt';
  final wrappedOriginal = Uint8List.fromList(utf8.encode('report body ' * 100));
  final wrapped = prependFilename(wrappedOriginal, wrappedFileName);
  final wrappedCompressed = CompressionService.instance.compress(wrapped);
  final wrappedEncrypted =
      EncryptionService.instance.encrypt(wrappedCompressed, password);
  final wrappedChunks = ChunkerService.instance
      .createChunksWithSize(
        data: wrappedEncrypted,
        payloadSize: 720,
        flags: 0x03, // FLAG_COMPRESSED | FLAG_ENCRYPTED
      )
      .chunks;

  final json = const JsonEncoder.withIndent('  ').convert({
    'payloadSize': 64,
    'original': hexOf(original),
    'chunks': result.chunks.map((c) => hexOf(c.toBytes())).toList(),
    'password': password,
    'encrypted': hexOf(encrypted),
    'gzipped': hexOf(gzipped),
    'crc32OfOriginal': crc,
    'originalText': hexOf(textPayload),
    'gzippedText': hexOf(CompressionService.instance.compress(textPayload)),
    'wrappedFileName': wrappedFileName,
    'wrappedOriginal': hexOf(wrappedOriginal),
    'wrappedPassword': password,
    'wrappedChunks': wrappedChunks.map((c) => hexOf(c.toBytes())).toList(),
  });

  final out = File('webapp/test/fixtures/dart_generated.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$json\n');
  stdout.writeln('Wrote ${out.path}');
}
