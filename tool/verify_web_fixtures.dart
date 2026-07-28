/// Verifies TS-generated fixtures decode with the app's production services.
/// Run from the repo root (after `npm run fixtures` in webapp/):
///   dart run tool/verify_web_fixtures.dart
/// Exits 0 on success, 1 on mismatch, 2 if the fixture file is missing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/core/services/chunker_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';

Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

({String fileName, Uint8List data})? extractFilename(Uint8List data) {
  if (data.length < 2) return null;
  final len = (data[0] << 8) | data[1];
  if (len == 0 || len > 255 || data.length < 2 + len) return null;
  try {
    final name = utf8.decode(data.sublist(2, 2 + len));
    return (fileName: name, data: Uint8List.sublistView(data, 2 + len));
  } catch (_) {
    return null;
  }
}

var failures = 0;

void check(bool condition, String label) {
  if (condition) {
    stdout.writeln('OK   $label');
  } else {
    stderr.writeln('FAIL $label');
    failures++;
  }
}

void main() {
  final file = File('webapp/test/fixtures/ts_generated.json');
  if (!file.existsSync()) {
    stderr.writeln('Missing ${file.path} — run `npm run fixtures` in webapp/ first');
    exit(2);
  }
  final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final original = fromHex(j['original'] as String);

  final chunks = (j['chunks'] as List)
      .map((h) => Chunk.fromBytes(fromHex(h as String)))
      .toList();
  final assembled = ChunkerService.instance.assembleChunks(chunks);
  check(bytesEqual(assembled, original), 'chunk decode + reassembly');

  final decrypted = EncryptionService.instance.decrypt(
    fromHex(j['encrypted'] as String),
    j['password'] as String,
  );
  check(bytesEqual(decrypted, original), 'AES-256-GCM decryption (trimmed password)');

  final gunzipped =
      CompressionService.instance.decompress(fromHex(j['gzipped'] as String));
  check(bytesEqual(gunzipped, original), 'gzip decompression');

  final originalText = fromHex(j['originalText'] as String);
  final gzippedText = fromHex(j['gzippedText'] as String);
  final gunzippedText = CompressionService.instance.decompress(gzippedText);
  check(
    bytesEqual(gunzippedText, originalText) &&
        gzippedText.length < originalText.length,
    'gzip decompression (compressed data)',
  );

  check(
    ChecksumService.instance.calculate(original) == j['crc32OfOriginal'],
    'CRC-32 agreement',
  );

  final wrappedChunks = (j['wrappedChunks'] as List)
      .map((h) => Chunk.fromBytes(fromHex(h as String)))
      .toList();
  final wrappedAssembled = ChunkerService.instance.assembleChunks(wrappedChunks);
  final wrappedDecrypted = EncryptionService.instance
      .decrypt(wrappedAssembled, j['wrappedPassword'] as String);
  final wrappedPlain = CompressionService.instance.decompress(wrappedDecrypted);
  final extracted = extractFilename(wrappedPlain);
  check(
    extracted != null &&
        extracted.fileName == j['wrappedFileName'] &&
        bytesEqual(extracted.data, fromHex(j['wrappedOriginal'] as String)),
    'filename-wrapped archive from TS (name + data)',
  );

  if (failures > 0) {
    stderr.writeln('$failures verification(s) failed');
    exit(1);
  }
  stdout.writeln('All TS fixtures verified against Dart core');
}
