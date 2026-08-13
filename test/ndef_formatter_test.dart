import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/nfc/ndef_bytes.dart';
import 'package:nfc_archiver/core/services/checksum_service.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_formatter.dart';
import 'package:nfc_manager/ndef_record.dart';

/// Characterization tests for the bytes `NdefFormatter` puts on a tag.
///
/// These pin the exact NDEF record fields rather than merely round-tripping,
/// because a round-trip is self-consistent: the app could change what it writes
/// and still read its own output perfectly while silently diverging from the
/// web app, which writes the same MIME record for NTAG (`webapp/src/nfc/ndef.ts`).
///
/// They exist so `chunkToNdef` can stop depending on `NdefRecord.createMime`,
/// which `nfc_manager` v4 removes (`ndef_record 1.4.2` ships only the general
/// constructor). Building the record explicitly must reproduce createMime's
/// output field for field; that is what these assert.

Chunk makeChunk(int payloadLen) {
  final payload =
      Uint8List.fromList(List.generate(payloadLen, (i) => (i * 7 + 5) % 256));
  return Chunk(
    archiveId: Uint8List(16)..fillRange(0, 16, 0xAB),
    totalChunks: 3,
    chunkIndex: 2,
    payload: payload,
    crc32: ChecksumService.instance.calculate(payload),
  );
}

void main() {
  final formatter = NdefFormatter.instance;

  test('chunkToNdef emits exactly one record', () {
    final message = formatter.chunkToNdef(makeChunk(64));
    expect(message.records, hasLength(1));
  });

  test('the record is a media record typed with the NFAR MIME string', () {
    final record = formatter.chunkToNdef(makeChunk(64)).records.single;

    expect(record.typeNameFormat, TypeNameFormat.media);
    expect(record.type, ascii.encode(nfarMimeType));
    expect(String.fromCharCodes(record.type),
        'application/vnd.nfcarchiver.chunk');
  });

  test('the record carries no identifier', () {
    // createMime passes an empty identifier. A non-empty one would add an ID
    // length byte to the header and shift every following byte on the tag.
    final record = formatter.chunkToNdef(makeChunk(64)).records.single;
    expect(record.identifier, isEmpty);
  });

  test('the payload is the serialized chunk, unmodified', () {
    final chunk = makeChunk(200);
    final record = formatter.chunkToNdef(chunk).records.single;

    expect(record.payload, chunk.toBytes());
  });

  test('a written record reads back as the same chunk', () {
    final chunk = makeChunk(120);
    final read = formatter.ndefToChunk(formatter.chunkToNdef(chunk));

    expect(read, isNotNull);
    expect(read!.payload, chunk.payload);
    expect(read.archiveId, chunk.archiveId);
    expect(read.chunkIndex, chunk.chunkIndex);
    expect(read.totalChunks, chunk.totalChunks);
  });

  test('a written record is recognised as holding an NFAR chunk', () {
    expect(formatter.containsNfarChunk(formatter.chunkToNdef(makeChunk(64))),
        isTrue);
  });

  group('agrees with the byte-level encoder used for the Chameleon', () {
    // NdefFormatter drives the phone path (nfc_manager hands over parsed
    // objects); encodeNdefMime drives the Chameleon path (raw pages over BLE)
    // and is the port of webapp/src/nfc/ndef.ts. Both write the same logical
    // record onto the same kind of tag, and until now nothing asserted they
    // agree — a tag written by the phone had to stay readable by the web app
    // purely on the strength of two independent implementations matching.

    /// TNF is the low 3 bits of the NDEF header byte; 0x02 is media.
    int tnfOf(Uint8List record) => record[0] & 0x07;

    test('both declare TNF media', () {
      final chunk = makeChunk(64);
      final record = formatter.chunkToNdef(chunk).records.single;

      expect(tnfOf(encodeNdefMime(chunk.toBytes())), 0x02);
      expect(record.typeNameFormat, TypeNameFormat.media);
    });

    test('both use the same MIME type bytes', () {
      final chunk = makeChunk(64);
      final raw = encodeNdefMime(chunk.toBytes());
      final typeLen = raw[1];
      // header(1) + typeLen(1) + payloadLen(1 when short) = 3
      final rawType = raw.sublist(3, 3 + typeLen);

      expect(rawType, formatter.chunkToNdef(chunk).records.single.type);
    });

    test('both carry the identical payload', () {
      for (final len in [16, 200, 255, 256, 700]) {
        final chunk = makeChunk(len);
        final bytes = chunk.toBytes();
        final raw = encodeNdefMime(bytes);
        final short = bytes.length < 256;
        final payloadStart = 2 + (short ? 1 : 4) + raw[1];

        expect(raw.sublist(payloadStart),
            formatter.chunkToNdef(chunk).records.single.payload,
            reason: 'payload $len must match across both encoders');
      }
    });
  });

  test('requiredNdefSize matches what the record actually costs', () {
    // The live write path compares this against `ndef.maxSize` to decide
    // whether a chunk fits, so it must not under-report the real record.
    for (final len in [16, 200, 255, 256, 700]) {
      final chunk = makeChunk(len);
      final record = formatter.chunkToNdef(chunk).records.single;

      expect(formatter.requiredNdefSize(chunk), greaterThanOrEqualTo(record.byteLength),
          reason: 'payload $len must not be under-reported');
    }
  });
}
