import 'dart:typed_data';

/// The Chameleon Ultra's framed command protocol, and an incremental parser
/// for responses arriving over BLE notifications.
///
/// Frame layout, big-endian throughout:
///
/// ```
/// offset  size  field
/// 0       2     SOF        0x11 0xEF      (0xEF is lrc([0x11]))
/// 2       2     command    uint16
/// 4       2     status     uint16
/// 6       2     dataLen    uint16
/// 8       1     head LRC   lrc(bytes 2..7)
/// 9       n     data
/// 9+n     1     data LRC   lrc(data)
/// ```
///
/// Total frame length is `10 + dataLen`.
///
/// Reimplemented in Dart from the MIT-licensed `chameleon-ultra.js`. A wire
/// protocol is not copyrightable and this shares no code with it.

/// Longitudinal redundancy check: the two's complement of the byte sum, so a
/// block plus its LRC sums to zero mod 256.
int lrc(Uint8List bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum += b;
  }
  return (0x100 - sum) & 0xff;
}

abstract final class ChameleonCmd {
  static const int getAppVersion = 1000;
  static const int changeDeviceMode = 1001;
  static const int hf14aScan = 2000;
  static const int mf1ReadOneBlock = 2008;
  static const int mf1WriteOneBlock = 2009;
  static const int hf14aRaw = 2010;
}

/// Response status codes, transcribed from the reference in full.
///
/// **There is no single "success" value.** Different command classes report
/// success differently: HF tag operations answer 0x00, LF operations 0x40, and
/// device-level commands (mode change, version) 0x68. Assuming one success code
/// is how the first hardware session failed — a perfectly good CHANGE_DEVICE_MODE
/// answered DEVICE_SUCCESS and was treated as an error.
abstract final class ChameleonStatus {
  /// IC card operation succeeded.
  static const int hfTagOk = 0x00;

  /// No card in the field. NOT an error when polling — it is the normal answer
  /// to a scan with nothing on the reader.
  static const int hfTagNotFound = 0x01;

  static const int hfErrStat = 0x02;
  static const int hfErrCrc = 0x03;
  static const int hfCollision = 0x04;
  static const int hfErrBcc = 0x05;

  /// Wrong key for the sector — a foreign card. A user situation, never a
  /// transport fault, so it must reach the caller as itself.
  static const int mfErrAuth = 0x06;

  static const int hfErrParity = 0x07;
  static const int hfErrAts = 0x08;

  /// LF tag operation succeeded.
  static const int lfTagOk = 0x40;

  static const int parErr = 0x60;
  static const int deviceModeError = 0x66;
  static const int invalidCmd = 0x67;

  /// Device-level operation succeeded.
  static const int deviceSuccess = 0x68;

  static const int notImplemented = 0x69;

  /// Every value that means "the command worked".
  static const Set<int> okValues = {hfTagOk, lfTagOk, deviceSuccess};

  /// A human-readable name, so a failure log says what happened rather than
  /// only which number came back.
  static String describe(int status) => switch (status) {
        hfTagOk => 'HF_TAG_OK',
        hfTagNotFound => 'HF_TAG_NOT_FOUND',
        hfErrStat => 'HF_ERR_STAT',
        hfErrCrc => 'HF_ERR_CRC',
        hfCollision => 'HF_COLLISION',
        hfErrBcc => 'HF_ERR_BCC',
        mfErrAuth => 'MF_ERR_AUTH',
        hfErrParity => 'HF_ERR_PARITY',
        hfErrAts => 'HF_ERR_ATS',
        lfTagOk => 'LF_TAG_OK',
        parErr => 'PAR_ERR',
        deviceModeError => 'DEVICE_MODE_ERROR',
        invalidCmd => 'INVALID_CMD',
        deviceSuccess => 'DEVICE_SUCCESS',
        notImplemented => 'NOT_IMPLEMENTED',
        _ => 'UNKNOWN',
      };
}

/// Device modes. The Chameleon boots into [emulator]; every HF command
/// requires [reader] first.
abstract final class ChameleonDeviceMode {
  static const int emulator = 0;
  static const int reader = 1;
}

class ChameleonFrame {
  const ChameleonFrame({
    required this.cmd,
    required this.status,
    required this.data,
  });

  final int cmd;
  final int status;
  final Uint8List data;
}

const int _sofHi = 0x11;
const int _sofLo = 0xEF;

/// The largest payload a Chameleon response can carry. A corrupt length field
/// must not make the parser wait forever for bytes that will never arrive.
const int _maxDataLen = 1024;

/// Build a command frame. Outgoing frames always carry a zero status.
Uint8List encodeFrame(int cmd, Uint8List data) {
  final out = Uint8List(10 + data.length);
  out[0] = _sofHi;
  out[1] = _sofLo;
  out[2] = (cmd >> 8) & 0xff;
  out[3] = cmd & 0xff;
  out[4] = 0;
  out[5] = 0;
  out[6] = (data.length >> 8) & 0xff;
  out[7] = data.length & 0xff;
  out[8] = lrc(Uint8List.sublistView(out, 2, 8));
  out.setRange(9, 9 + data.length, data);
  out[out.length - 1] = lrc(data);
  return out;
}

/// Reassembles frames from the arbitrary byte chunks BLE delivers.
///
/// BLE gives no framing guarantees: one notification may carry half a frame,
/// two frames, or a frame plus the start of the next. Assuming aligned
/// notifications is the most likely way a port of this protocol fails on real
/// hardware, so the parser buffers and resynchronises rather than assuming.
///
/// On a checksum mismatch it advances exactly **one** byte and rescans for the
/// SOF, matching the reference. Dropping the whole buffer instead would discard
/// a healthy frame that follows corruption inside the same notification.
class FrameParser {
  final List<int> _buf = [];

  List<ChameleonFrame> feed(Uint8List chunk) {
    _buf.addAll(chunk);
    final out = <ChameleonFrame>[];

    for (;;) {
      final sof = _indexOfSof();
      if (sof < 0) {
        // No SOF anywhere. Discard the garbage, but keep a trailing 0x11 — it
        // may be the first half of a SOF split across two notifications.
        // Keeping only that one byte matters: retaining the whole buffer
        // whenever it happened to end in 0x11 would grow without bound on a
        // noisy link.
        final partialSof = _buf.isNotEmpty && _buf.last == _sofHi;
        _buf.clear();
        if (partialSof) _buf.add(_sofHi);
        break;
      }
      if (sof > 0) _buf.removeRange(0, sof);
      if (_buf.length < 10) break; // header not complete yet

      final headLrc = lrc(Uint8List.fromList(_buf.sublist(2, 8)));
      if (headLrc != _buf[8]) {
        _buf.removeAt(0);
        continue;
      }

      final dataLen = (_buf[6] << 8) | _buf[7];
      if (dataLen > _maxDataLen) {
        // Corrupt length that passed the head LRC by coincidence. Skip a byte
        // rather than blocking on bytes that will never arrive.
        _buf.removeAt(0);
        continue;
      }

      final total = 10 + dataLen;
      if (_buf.length < total) break; // payload still arriving

      final data = Uint8List.fromList(_buf.sublist(9, 9 + dataLen));
      if (lrc(data) != _buf[total - 1]) {
        _buf.removeAt(0);
        continue;
      }

      out.add(ChameleonFrame(
        cmd: (_buf[2] << 8) | _buf[3],
        status: (_buf[4] << 8) | _buf[5],
        data: data,
      ));
      _buf.removeRange(0, total);
    }

    return out;
  }

  int _indexOfSof() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == _sofHi && _buf[i + 1] == _sofLo) return i;
    }
    return -1;
  }

  void reset() => _buf.clear();
}
