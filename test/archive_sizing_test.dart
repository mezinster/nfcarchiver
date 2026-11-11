import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/services/archive_sizing.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';
import 'package:nfc_archiver/features/archive/data/archive_repository.dart';

void main() {
  final repo = ArchiveRepository.instance;
  final names = ['a.jpg', 'IMG_1234.jpg', '${'x' * 300}.jpg'];

  test('filenameWrapperBytes caps the name at 255 bytes', () {
    expect(filenameWrapperBytes('a.jpg'), 7);
    expect(filenameWrapperBytes('é.jpg'), 2 + 6);
    expect(filenameWrapperBytes('x' * 300), 257);
  });

  test('photoByteBudget reserves wrapper and encryption overhead', () {
    expect(
      photoByteBudget(
          tags: 2, tagType: NfcTagType.ntag216, fileName: 'a.jpg'),
      2 * NfcTagType.ntag216.maxPayloadSize -
          7 -
          EncryptionService.encryptionOverhead,
    );
    expect(
      photoByteBudget(
          tags: 1, tagType: NfcTagType.ntag213, fileName: 'a.jpg'),
      lessThan(NfcTagType.ntag213.maxPayloadSize),
    );
  });

  for (final type in NfcTagType.values.where((t) => t.maxPayloadSize > 0)) {
    test('tagsNeeded matches real chunk count for ${type.name}', () async {
      final payload = type.maxPayloadSize;
      for (final size in [0, 1, payload - 1, payload, 5 * payload + 3]) {
        for (final name in names) {
          for (final encrypt in [false, true]) {
            final result = await repo.createArchiveFromBytes(
              data: Uint8List(size),
              fileName: name,
              tagType: type,
              password: encrypt ? 'pw' : null,
            );
            final archived = archivedByteCount(
                dataSize: size, fileName: name, encrypt: encrypt);
            final label = '${type.name} size=$size name=${name.length} '
                'enc=$encrypt';
            expect(tagsNeeded(archived, type), result.chunks.length,
                reason: label);
            final est = repo.estimateFromSize(
              dataSize: size,
              fileName: name,
              tagType: type,
              encrypt: encrypt,
            );
            expect(est.chunksNeeded, result.chunks.length, reason: label);
          }
        }
      }
    });
  }
}
