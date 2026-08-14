import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/models/nfc_tag_info.dart';
import '../../../core/chameleon/chameleon_device.dart';
import '../domain/card_reader.dart';
import 'nfc_capabilities.dart';
import 'nfc_repository.dart';

/// The phone's own NFC radio, behind the [CardReader] seam.
///
/// **Pure delegation, deliberately.** Not one line of session, cooldown or
/// codec logic moved out of [NfcRepository] — this only forwards. That is what
/// makes "the phone path cannot have regressed" a checkable claim rather than a
/// hope: every pre-existing test still exercises the same code through the same
/// calls.
class PhoneNfcReader implements CardReader {
  PhoneNfcReader([NfcRepository? repository])
      : _repository = repository ?? NfcRepository.instance;

  final NfcRepository _repository;

  @override
  String get name => 'phone-nfc';

  /// The phone stack exposes no raw anticollision or arbitrary block access,
  /// so the card inspector can never run on it. A permanent property of the
  /// platform, not a deferred feature.
  @override
  bool get supportsRawAccess => false;

  @override
  ChameleonDevice? get rawDevice => null;

  @override
  bool get isInWriteCooldown => _repository.isInWriteCooldown;

  /// No-ops: the phone's radio needs no connection phase. Implemented rather
  /// than special-cased at call sites, so the contract stays honest.
  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> initCapabilities() => _repository.initCapabilities();

  @override
  Future<bool> isAvailable() => _repository.isAvailable();

  /// The one capability that is genuinely the phone's own: whether this
  /// handset's NFC controller speaks CRYPTO1. Answered by the platform channel
  /// rather than the repository because it is hardware, not session, state —
  /// and it is false on every iPhone, where the channel does not exist.
  @override
  Future<bool> supportsMifareClassic() => hasMifareClassicSupport();

  @override
  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    String alertMessage = 'Hold your device near an NFC tag',
  }) =>
      _repository.startReadSession(
        onChunkRead: onChunkRead,
        onError: onError,
        onTagDiscovered: onTagDiscovered,
        alertMessage: alertMessage,
      );

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
    String alertMessage = 'Hold your device near an NFC tag to write',
  }) =>
      _repository.startWriteSession(
        chunk: chunk,
        configuredTagType: configuredTagType,
        onSuccess: onSuccess,
        onError: onError,
        onTagTooSmall: onTagTooSmall,
        onTagTypeMismatch: onTagTypeMismatch,
        alertMessage: alertMessage,
      );

  @override
  Future<NfcReadResult> readTag({
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _repository.readTag(timeout: timeout);

  @override
  Future<NfcWriteResult> writeTag({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _repository.writeTag(
        chunk: chunk,
        configuredTagType: configuredTagType,
        timeout: timeout,
      );

  @override
  void stopSession({String? message}) =>
      _repository.stopSession(message: message);

  @override
  void clearWriteCooldown() => _repository.clearWriteCooldown();
}
