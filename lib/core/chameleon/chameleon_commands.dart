import 'dart:typed_data';

import 'chameleon_device.dart';

/// Payload encoding and response parsing for the Chameleon commands this app
/// uses.
///
/// Kept as pure functions, separate from the BLE plumbing, because this is
/// where the bugs live and none of it needs a radio to test. `BleChameleonDevice`
/// is then thin enough that the only untested part is the transport itself.
///
/// Reimplemented in Dart from the MIT reference; a wire protocol is not
/// copyrightable and this shares no code with it.

/// Mifare key type A. (Key B exists but this app only ever uses factory key A
/// and never writes a sector trailer.)
const int mf1KeyA = 0x60;

/// `MF1_READ_ONE_BLOCK` payload: `keyType(1) block(1) key(6)`.
Uint8List encodeReadBlock(int block, Uint8List key) {
  if (key.length != 6) {
    throw ArgumentError('A Mifare key is 6 bytes, got ${key.length}');
  }
  return Uint8List.fromList([mf1KeyA, block, ...key]);
}

/// `MF1_WRITE_ONE_BLOCK` payload: `keyType(1) block(1) key(6) data(16)`.
Uint8List encodeWriteBlock(int block, Uint8List key, Uint8List data) {
  if (key.length != 6) {
    throw ArgumentError('A Mifare key is 6 bytes, got ${key.length}');
  }
  if (data.length != 16) {
    throw ArgumentError('A Mifare block is 16 bytes, got ${data.length}');
  }
  return Uint8List.fromList([mf1KeyA, block, ...key, ...data]);
}

/// `CHANGE_DEVICE_MODE` payload: one byte.
Uint8List encodeChangeDeviceMode(int mode) => Uint8List.fromList([mode]);

/// `HF14A_RAW` payload: `options(1) timeout(2) dataBitLength(2) frame(n)`.
///
/// The options byte is packed **MSB-first** — bit offset 0 is the most
/// significant bit, not the least. Getting that backwards silently sends the
/// wrong flags and the symptom is a reader that never answers.
///
/// [dataBitLength] is normalised the way the reference does: 0 means "all of
/// the final byte", so a whole-byte frame reports `len * 8`. A 7-bit frame
/// (WUPA, REQA) must be declared as 7 — sending it as 8 gets no answer at all.
Uint8List encodeHf14aRaw(
  Uint8List frame, {
  bool activateRfField = false,
  bool waitResponse = true,
  bool appendCrc = false,
  bool autoSelect = false,
  bool keepRfField = false,
  bool checkResponseCrc = false,
  int timeoutMs = 1000,
  int dataBitLength = 0,
}) {
  var options = 0;
  void setBit(int offset, bool value) {
    if (value) options |= 0x80 >> offset;
  }

  setBit(0, activateRfField);
  setBit(1, waitResponse);
  setBit(2, appendCrc);
  setBit(3, autoSelect);
  setBit(4, keepRfField);
  setBit(5, checkResponseCrc);

  final bits = frame.isEmpty
      ? 0
      : (frame.length - 1) * 8 + ((dataBitLength + 7) % 8) + 1;

  return Uint8List.fromList([
    options,
    (timeoutMs >> 8) & 0xff,
    timeoutMs & 0xff,
    (bits >> 8) & 0xff,
    bits & 0xff,
    ...frame,
  ]);
}

/// Parse the first tag out of an `HF14A_SCAN` response.
///
/// Record layout: `uidLen(1) uid(uidLen) atqa(2) sak(1) atsLen(1) ats(atsLen)`.
///
/// An empty response means **no tag in the field**, which is the normal state
/// of a reader waiting for a tap — so it returns null rather than throwing.
ScannedTag? parseScanResponse(Uint8List data) {
  if (data.isEmpty) return null;

  final uidLen = data[0];
  if (data.length < uidLen + 4) {
    throw CardReadException(
      'Scan response too short for a $uidLen-byte UID (${data.length} bytes)',
    );
  }
  final atsLen = data[uidLen + 4];
  if (data.length < uidLen + atsLen + 5) {
    throw CardReadException(
      'Scan response too short for a $atsLen-byte ATS (${data.length} bytes)',
    );
  }

  return ScannedTag(
    uid: Uint8List.sublistView(data, 1, 1 + uidLen),
    atqa: Uint8List.sublistView(data, 1 + uidLen, 3 + uidLen),
    sak: data[3 + uidLen],
  );
}
