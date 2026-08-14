import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/features/nfc/data/chameleon_reader.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_capabilities.dart';
import 'package:nfc_archiver/features/nfc/data/phone_nfc_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/tag_type_availability.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';

import 'support/fake_card_reader.dart';
import 'support/fake_chameleon_device.dart';

/// Who may offer Mifare Classic is a property of the READER, not the phone.
///
/// CRYPTO1 lives in the reader chip. The phone's own controller has it only on
/// NXP hardware and never on iOS, but a Chameleon always does — which is why
/// iOS plus a Chameleon reaches the app's primary medium that iOS's own radio
/// can never touch. Gating the UI on the phone alone hid Mifare Classic on
/// every iPhone even with a reader attached; these tests pin the reader-aware
/// rule that replaced it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockController({bool? hasMifare}) {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      if (hasMifare == null) throw MissingPluginException('no implementation');
      return hasMifare;
    });
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, null);
  });

  group('reader capability', () {
    test('a Chameleon can always do Mifare Classic', () async {
      // Unconditional on purpose, exactly like isAvailable(): CRYPTO1 runs on
      // the reader, so the phone underneath is irrelevant. This is the whole
      // reason the reader path is iOS's only route to the medium.
      mockController(hasMifare: null); // iOS: no channel at all
      final reader = ChameleonReader(
        FakeChameleonDevice.classic1k(),
        pollInterval: Duration.zero,
      );
      expect(await reader.supportsMifareClassic(), isTrue);
    });

    test('the phone radio answers from its own controller', () async {
      mockController(hasMifare: true);
      expect(await PhoneNfcReader().supportsMifareClassic(), isTrue);
      mockController(hasMifare: false);
      expect(await PhoneNfcReader().supportsMifareClassic(), isFalse);
    });

    test('the phone radio says no when the channel is absent (iOS)', () async {
      mockController(hasMifare: null);
      expect(await PhoneNfcReader().supportsMifareClassic(), isFalse);
    });
  });

  group('mifareClassicAvailableProvider follows the active reader', () {
    ProviderContainer container({required FakeCardReader phone,
        required FakeCardReader chameleon}) {
      final c = ProviderContainer(overrides: [
        readerControllerProvider.overrideWith((ref) => ReaderController(
              makePhone: () => phone,
              makeChameleon: (_) => chameleon,
            )),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('false on a phone whose controller lacks CRYPTO1', () async {
      final c = container(
        phone: FakeCardReader(
            name: 'phone-nfc', supportsRawAccess: false, mifareClassic: false),
        chameleon: FakeCardReader(
            name: 'chameleon-ble', supportsRawAccess: true, mifareClassic: true),
      );
      expect(await c.read(mifareClassicAvailableProvider.future), isFalse);
    });

    test('true once a Chameleon is the active reader, even on iOS', () async {
      // The regression this fixes: an iPhone reports no Mifare support (there
      // is no platform channel), so the option stayed hidden after the user
      // connected a reader that can do it.
      final c = container(
        phone: FakeCardReader(
            name: 'phone-nfc', supportsRawAccess: false, mifareClassic: false),
        chameleon: FakeCardReader(
            name: 'chameleon-ble', supportsRawAccess: true, mifareClassic: true),
      );
      expect(await c.read(mifareClassicAvailableProvider.future), isFalse);

      await c
          .read(readerControllerProvider.notifier)
          .select(ReaderKind.chameleon, deviceId: 'AA:BB');

      expect(await c.read(mifareClassicAvailableProvider.future), isTrue);
    });

    test('back to false when the reader is dropped', () async {
      // Symmetry matters: the option must vanish again, or an archive would be
      // chunked for a medium the phone alone cannot write.
      final c = container(
        phone: FakeCardReader(
            name: 'phone-nfc', supportsRawAccess: false, mifareClassic: false),
        chameleon: FakeCardReader(
            name: 'chameleon-ble', supportsRawAccess: true, mifareClassic: true),
      );
      final controller = c.read(readerControllerProvider.notifier);
      await controller.select(ReaderKind.chameleon, deviceId: 'AA:BB');
      expect(await c.read(mifareClassicAvailableProvider.future), isTrue);

      await controller.disconnect();
      expect(await c.read(mifareClassicAvailableProvider.future), isFalse);
    });
  });

  group('selectableTagTypes', () {
    test('never offers Custom, which has no fixed capacity', () {
      expect(selectableTagTypes(mifareAvailable: true),
          isNot(contains(NfcTagType.custom)));
    });

    test('offers Mifare Classic only when the reader can write it', () {
      expect(selectableTagTypes(mifareAvailable: true),
          contains(NfcTagType.mifareClassic1k));
      expect(selectableTagTypes(mifareAvailable: false),
          isNot(contains(NfcTagType.mifareClassic1k)));
    });

    test('the NDEF types are unaffected by the Mifare gate', () {
      final withMifare = selectableTagTypes(mifareAvailable: true)
          .where((t) => t.medium == TagMedium.ndef);
      final without = selectableTagTypes(mifareAvailable: false)
          .where((t) => t.medium == TagMedium.ndef);
      expect(without, orderedEquals(withMifare));
    });
  });
}
