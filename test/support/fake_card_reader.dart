import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/core/models/nfc_tag_info.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/nfc_failure.dart';

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
    this.available = true,
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
  Future<bool> isAvailable() async => available;

  /// What [isAvailable] answers.
  final bool available;

  /// Thrown by [startReadSession] when set, to play a reader that fails to arm.
  Object? readSessionError;

  @override
  bool get isInWriteCooldown => false;

  @override
  void clearWriteCooldown() {}

  @override
  void stopSession({String? message}) {}

  /// The latest read arm's callbacks, so a test can play the reader's part.
  void Function(Chunk chunk, NfcTagInfo tagInfo)? lastOnChunkRead;
  void Function(NfcFailure failure)? lastOnError;
  void Function(ScanStop reason)? lastOnStopped;
  int readArms = 0;

  /// Calls of the stop closures handed out by startReadSession.
  int readStops = 0;
  /// endTag calls, as 'message' or 'problem: message'.
  final List<String> endedTags = [];

  @override
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(NfcFailure failure) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    void Function(ScanStop reason)? onStopped,
    String alertMessage = '',
  }) async {
    readArms++;
    final error = readSessionError;
    if (error != null) throw error;
    lastOnChunkRead = onChunkRead;
    lastOnError = onError;
    lastOnStopped = onStopped;
    return () => readStops++;
  }

  @override
  void endTag(String message, {bool problem = false}) =>
      endedTags.add(problem ? 'problem: $message' : message);

  void Function(ScanStop reason)? lastWriteOnStopped;

  @override
  Future<void Function()> startWriteSession({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    required void Function(NfcTagInfo tagInfo) onSuccess,
    required void Function(NfcFailure failure) onError,
    void Function(int requiredSize, int detectedCapacity, NfcTagInfo? tagInfo)?
        onTagTooSmall,
    void Function(String tappedMedium, String configuredMedium,
            NfcTagInfo? tagInfo)?
        onTagTypeMismatch,
    void Function(ScanStop reason)? onStopped,
    String alertMessage = '',
  }) async {
    lastWriteOnStopped = onStopped;
    return () {};
  }

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
