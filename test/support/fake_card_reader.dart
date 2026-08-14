import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';

/// A [CardReader] that records lifecycle calls, for testing reader selection.
///
/// Only connect/disconnect behaviour matters here — session and write paths
/// are covered by the real readers' own tests, so they are left unimplemented
/// rather than given fake behaviour nothing asserts on.
class FakeCardReader implements CardReader {
  FakeCardReader({
    required this.name,
    required this.supportsRawAccess,
    this.mifareClassic = false,
    this.failConnect = false,
  });

  @override
  final String name;

  @override
  final bool supportsRawAccess;

  /// What this reader claims about CRYPTO1 — the real readers differ, so the
  /// fake must be able to differ too.
  final bool mifareClassic;

  @override
  Future<bool> supportsMifareClassic() async => mifareClassic;

  /// Mirrors the real contract: non-null exactly when raw access is offered.
  @override
  ChameleonDevice? get rawDevice => supportsRawAccess ? rawDeviceStub : null;

  /// Set by tests that need the device identity to be checkable.
  ChameleonDevice? rawDeviceStub;

  final bool failConnect;

  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (failConnect) throw StateError('could not reach the reader');
  }

  @override
  Future<void> disconnect() async => disconnectCalls++;

  @override
  Future<void> initCapabilities() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  bool get isInWriteCooldown => false;

  @override
  void clearWriteCooldown() {}

  @override
  void stopSession({String? message}) {}

  @override
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    String alertMessage = '',
  }) async =>
      () {};

  @override
  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(String message) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)?
        onTagTooSmall,
    void Function(String tappedMedium, String configuredMedium,
            NfcTagInfo? tagInfo)?
        onTagTypeMismatch,
    String alertMessage = '',
  }) async =>
      () {};

  @override
  Future<NfcReadResult> readTag({Duration timeout = const Duration(seconds: 30)}) =>
      throw UnimplementedError();

  @override
  Future<NfcWriteResult> writeTag({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      throw UnimplementedError();
}
