import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'support/helpers.dart';
void main() {
  test('validChunkBytes round-trips through the production decoder', () {
    final bytes = validChunkBytes();
    final back = Chunk.fromBytes(bytes);
    expect(back.payload.length, 32);
    expect(back.archiveIdString, aChunk().archiveIdString);
  });
}
