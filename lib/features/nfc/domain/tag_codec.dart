import 'package:nfc_manager/nfc_manager.dart';

import '../../../core/models/chunk.dart';

/// How one storage medium carries an NFAR chunk on a tag.
///
/// `NfcRepository` owns sessions, cooldowns and errors; a codec owns the bytes.
/// Mirrors the web app's `Transport` seam so the two codebases stay legible to
/// each other.
abstract interface class TagCodec {
  /// Short identifier for logs and error messages, e.g. 'NDEF'.
  String get name;

  /// Whether this codec can handle the tapped tag.
  bool supports(NfcTag tag);

  /// Largest serialized chunk this tag can hold.
  ///
  /// Defined as chunk bytes, NOT the medium's raw size, so the two codecs
  /// return comparable numbers: the caller checks `chunk.totalSize > capacity`
  /// without knowing which medium it is talking to.
  Future<int> capacityBytes(NfcTag tag);

  /// Read a chunk, or null if the tag holds no valid NFAR data.
  Future<Chunk?> readChunk(NfcTag tag);

  /// Write a chunk. Throws on failure.
  Future<void> writeChunk(NfcTag tag, Chunk chunk);
}
