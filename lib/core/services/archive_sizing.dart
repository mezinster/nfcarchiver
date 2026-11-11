import 'dart:convert';

import '../constants/nfar_format.dart';
import 'encryption_service.dart';

/// Bytes the filename wrapper adds before the data: a 2-byte length plus the
/// UTF-8 name, capped at 255 bytes (mirrors `_prependFilenameMetadata`).
int filenameWrapperBytes(String fileName) {
  final n = utf8.encode(fileName).length;
  return 2 + (n > 255 ? 255 : n);
}

/// Size of the archived stream for uncompressed data: wrapper + data, plus the
/// encryption overhead when [encrypt] is set.
int archivedByteCount({
  required int dataSize,
  required String fileName,
  required bool encrypt,
}) {
  return dataSize +
      filenameWrapperBytes(fileName) +
      (encrypt ? EncryptionService.encryptionOverhead : 0);
}

/// Number of tags (chunks) needed for [archivedBytes].
int tagsNeeded(int archivedBytes, NfcTagType tagType) =>
    tagType.chunksNeeded(archivedBytes);

/// Bytes a photo may occupy so that, with the filename wrapper and the
/// encryption overhead reserved, it still fits [tags] tags. May be <= 0.
int photoByteBudget({
  required int tags,
  required NfcTagType tagType,
  required String fileName,
}) {
  return tags * tagType.maxPayloadSize -
      filenameWrapperBytes(fileName) -
      EncryptionService.encryptionOverhead;
}
