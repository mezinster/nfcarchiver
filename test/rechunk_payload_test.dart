import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';

void main() {
  group('NfcTagType.payloadForCapacity', () {
    test('Mifare carries the raw chunk: only header and CRC come off', () {
      expect(NfcTagType.payloadForCapacity(752, TagMedium.mifareClassic), 720);
      expect(
          NfcTagType.payloadForCapacity(3440, TagMedium.mifareClassic), 3408);
    });

    test('NDEF delegates to maxPayloadForCapacity', () {
      expect(NfcTagType.payloadForCapacity(504, TagMedium.ndef),
          NfcTagType.maxPayloadForCapacity(504));
    });

    test('Mifare 4K tag type holds a 3408 B payload', () {
      expect(NfcTagType.mifareClassic4k.capacity, MifareCardSize.k4.capacityBytes);
      expect(NfcTagType.mifareClassic4k.maxPayloadSize, 3408);
      expect(NfcTagType.mifareClassic4k.medium, TagMedium.mifareClassic);
    });
  });

  group('ArchiveNotifier.rechunkForDetectedCapacity', () {
    Future<ArchiveNotifier> prepared4k() async {
      final dir = Directory.systemTemp.createTempSync('rechunk');
      addTearDown(() => dir.delete(recursive: true));
      final rnd = Random(1);
      final file = File('${dir.path}/a.bin')
        ..writeAsBytesSync(
            Uint8List.fromList(List.generate(5000, (_) => rnd.nextInt(256))));
      final n = ArchiveNotifier();
      n.selectFile(filePath: file.path, fileName: 'a.bin', fileSize: 5000);
      n.configure(
          tagType: NfcTagType.mifareClassic4k, compress: false, encrypt: false);
      await n.prepareArchive();
      expect(n.state, isA<ArchiveReady>());
      return n;
    }

    test('a Mifare medium re-chunks to 720 B payloads, not the NDEF 680',
        () async {
      final n = await prepared4k();
      final count =
          n.rechunkForDetectedCapacity(752, medium: TagMedium.mifareClassic);
      expect(count, isNotNull);
      final sizes = (n.state as ArchiveReady)
          .result
          .chunks
          .map((c) => c.payload.length)
          .toList();
      expect(sizes.every((s) => s <= 720), isTrue);
      expect(sizes, contains(720));
    });
  });
}
