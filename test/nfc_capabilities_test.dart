import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/nfc_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, null);
  });

  test('reports true when the platform says the feature is present', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      expect(call.method, 'hasMifareClassic');
      return true;
    });
    expect(await hasMifareClassicSupport(), isTrue);
  });

  test('reports false when the platform says it is absent', () async {
    messenger.setMockMethodCallHandler(
        nfcCapabilitiesChannel, (call) async => false);
    expect(await hasMifareClassicSupport(), isFalse);
  });

  test('reports false when the channel is unimplemented (iOS)', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      throw MissingPluginException('no implementation');
    });
    expect(await hasMifareClassicSupport(), isFalse);
  });

  test('reports false rather than throwing on any platform error', () async {
    messenger.setMockMethodCallHandler(nfcCapabilitiesChannel, (call) async {
      throw PlatformException(code: 'ERROR');
    });
    expect(await hasMifareClassicSupport(), isFalse);
  });
}
