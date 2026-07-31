import '../../../core/constants/nfar_format.dart';
import '../../../core/models/chunk.dart';
import '../../../core/models/nfc_tag_info.dart';
import '../data/nfc_repository.dart';

/// A source of card reads and writes.
///
/// **Extracted from [NfcRepository]'s existing public API, not invented.** Every
/// member below keeps that class's current signature, so `nfc_provider.dart` and
/// both notifiers compile against this seam with no call-site edits — which is
/// the only real evidence that swapping the phone radio for a Chameleon changes
/// nothing about how archiving and restoring behave.
///
/// Note the shape that is easy to get wrong: the two session starters are
/// asynchronous **and return a stop closure**, *and* a separate [stopSession]
/// also exists. Both are load-bearing and both survive.
abstract class CardReader {
  /// 'phone-nfc' or 'chameleon-ble'.
  String get name;

  /// Whether arbitrary ISO 14443-A frames can be sent.
  ///
  /// True only for a Chameleon, and the gate for the card inspector: the phone
  /// stack exposes no raw anticollision or arbitrary block access, so this is a
  /// permanent property of the medium, not a missing feature.
  bool get supportsRawAccess;

  bool get isInWriteCooldown;

  /// Bring the reader up. A no-op for the phone radio, which is always there;
  /// a BLE connection for a Chameleon.
  Future<void> connect();

  Future<void> disconnect();

  Future<void> initCapabilities();

  Future<bool> isAvailable();

  Future<void Function()> startReadSession({
    required void Function(Chunk chunk, NfcTagInfo tagInfo) onChunkRead,
    required void Function(String message) onError,
    void Function(NfcTagInfo tagInfo)? onTagDiscovered,
    String alertMessage,
  });

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
    String alertMessage,
  });

  Future<NfcReadResult> readTag({Duration timeout});

  Future<NfcWriteResult> writeTag({
    required Chunk chunk,
    required NfcTagType configuredTagType,
    Duration timeout,
  });

  void stopSession({String? message});

  void clearWriteCooldown();
}
