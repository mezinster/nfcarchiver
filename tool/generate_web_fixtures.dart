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

import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/core/services/chunker_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';
import 'package:nfc_archiver/features/archive/data/archive_repository.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
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
  // Exercise the real Android archive path — ArchiveRepository.createArchiveFromBytes
  // — rather than a hand-rolled replica, so wrapper/flag drift can't hide. This is
  // constructible in a plain CLI: it (and its core services) have no NFC/Flutter
  // plugin dependency, only pure-Dart packages (equatable, uuid, pointycastle).
  final wrappedResult = await ArchiveRepository.instance.createArchiveFromBytes(
    data: wrappedOriginal,
    fileName: wrappedFileName,
    tagType: NfcTagType.generic1k,
    compress: true,
    password: password,
  );
  final wrappedChunks = wrappedResult.chunks;

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
