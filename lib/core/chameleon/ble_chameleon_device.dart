import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'chameleon_commands.dart';
import 'chameleon_device.dart';
import 'chameleon_frame.dart';

/// A Chameleon Ultra reached over Bluetooth LE.
///
/// The device exposes a **Nordic UART Service**: commands are written to the RX
/// characteristic and responses arrive as notifications on TX, which are fed to
/// a [FrameParser] because BLE gives no framing guarantees.
///
/// This class is deliberately thin. Everything with logic in it — the frame
/// codec, the command payloads, the response parsing — lives in
/// [chameleon_frame.dart] and [chameleon_commands.dart] and is unit-tested, so
/// the only part that genuinely needs hardware is the transport below.
class BleChameleonDevice implements ChameleonDevice {
  BleChameleonDevice({
    required this.deviceId,
    FlutterReactiveBle? ble,
  }) : _ble = ble ?? FlutterReactiveBle();

  /// Nordic UART Service. The DFU service the device also advertises
  /// (`8ec90001-…`) is deliberately never touched — this app does not do
  /// firmware updates, and a stray write there could brick the reader.
  static final Uuid serviceUuid =
      Uuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final Uuid rxCharUuid =
      Uuid.parse('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final Uuid txCharUuid =
      Uuid.parse('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  final String deviceId;
  final FlutterReactiveBle _ble;

  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  final FrameParser _parser = FrameParser();

  /// One in-flight command at a time. The protocol is strictly
  /// request/response, and interleaving would make responses ambiguous.
  Completer<ChameleonFrame>? _pending;
  int? _pendingCmd;

  bool _connected = false;

  /// The mode the device is believed to be in, cached so reader mode is not
  /// re-sent before every command.
  int? _deviceMode;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    if (_connected) return;

    final ready = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
      (update) {
        if (update.connectionState == DeviceConnectionState.connected) {
          if (!ready.isCompleted) ready.complete();
        } else if (update.connectionState ==
            DeviceConnectionState.disconnected) {
          _onLinkLost();
          if (!ready.isCompleted) {
            ready.completeError(
              const CardReadException('The Chameleon disconnected while connecting'),
            );
          }
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
      },
    );

    await ready.future;

    _notifySub = _ble.subscribeToCharacteristic(_char(txCharUuid)).listen(
      (bytes) => _onNotification(Uint8List.fromList(bytes)),
      onError: (Object _) => _onLinkLost(),
    );

    _connected = true;

    // The Chameleon boots into EMULATOR mode and silently refuses every HF
    // command until switched. This is invisible from the device seam — the
    // reference hides it inside each command — so it is done once, here, and
    // then asserted by a liveness check rather than left to call sites.
    await _sendCommand(
      ChameleonCmd.changeDeviceMode,
      encodeChangeDeviceMode(ChameleonDeviceMode.reader),
    );
    _deviceMode = ChameleonDeviceMode.reader;

    // Proves the link actually carries frames, so a half-open GATT connection
    // fails here rather than at the first card operation.
    await _sendCommand(ChameleonCmd.getAppVersion, Uint8List(0));
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _deviceMode = null;
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _failPending(const CardReadException('Disconnected'));
    _parser.reset();
  }

  @override
  Future<ScannedTag?> scanTag() async {
    await _assureReaderMode();
    final frame = await _sendCommand(ChameleonCmd.hf14aScan, Uint8List(0));
    // An empty payload means no tag in the field — the normal state of a
    // reader waiting for a tap, never an error.
    return parseScanResponse(frame.data);
  }

  @override
  Future<Uint8List> transceive14a(
    Uint8List data, {
    bool appendCrc = false,
    bool autoSelect = false,
    bool checkResponseCrc = false,
    bool activateRfField = false,
    bool keepRfField = false,
    int dataBitLength = 0,
  }) async {
    await _assureReaderMode();
    final frame = await _sendCommand(
      ChameleonCmd.hf14aRaw,
      encodeHf14aRaw(
        data,
        appendCrc: appendCrc,
        autoSelect: autoSelect,
        checkResponseCrc: checkResponseCrc,
        activateRfField: activateRfField,
        keepRfField: keepRfField,
        dataBitLength: dataBitLength,
      ),
    );
    return frame.data;
  }

  @override
  Future<Uint8List> readBlock(int block, Uint8List key) async {
    await _assureReaderMode();
    final frame = await _sendCommand(
      ChameleonCmd.mf1ReadOneBlock,
      encodeReadBlock(block, key),
    );
    return frame.data;
  }

  @override
  Future<void> writeBlock(int block, Uint8List key, Uint8List data) async {
    await _assureReaderMode();
    await _sendCommand(
      ChameleonCmd.mf1WriteOneBlock,
      encodeWriteBlock(block, key, data),
    );
  }

  // ---- internals ------------------------------------------------------------

  QualifiedCharacteristic _char(Uuid id) => QualifiedCharacteristic(
        serviceId: serviceUuid,
        characteristicId: id,
        deviceId: deviceId,
      );

  Future<void> _assureReaderMode() async {
    if (_deviceMode == ChameleonDeviceMode.reader) return;
    await _sendCommand(
      ChameleonCmd.changeDeviceMode,
      encodeChangeDeviceMode(ChameleonDeviceMode.reader),
    );
    _deviceMode = ChameleonDeviceMode.reader;
  }

  Future<ChameleonFrame> _sendCommand(
    int cmd,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_connected && cmd != ChameleonCmd.changeDeviceMode &&
        cmd != ChameleonCmd.getAppVersion) {
      throw const CardReadException('Not connected to a Chameleon');
    }
    if (_pending != null) {
      throw StateError('A Chameleon command is already in flight');
    }

    final completer = Completer<ChameleonFrame>();
    _pending = completer;
    _pendingCmd = cmd;

    try {
      await _ble.writeCharacteristicWithoutResponse(
        _char(rxCharUuid),
        value: encodeFrame(cmd, data),
      );
      final frame = await completer.future.timeout(
        timeout,
        onTimeout: () => throw TagTimeoutException(
          'The Chameleon did not answer command $cmd within '
          '${timeout.inMilliseconds}ms',
        ),
      );
      _throwForStatus(cmd, frame.status);
      return frame;
    } finally {
      _pending = null;
      _pendingCmd = null;
    }
  }

  void _onNotification(Uint8List bytes) {
    for (final frame in _parser.feed(bytes)) {
      final pending = _pending;
      // A frame for a command we are not waiting on is stale — most likely the
      // late answer to a command that already timed out. Dropping it is
      // correct: completing the CURRENT waiter with it would answer the wrong
      // question, which is the same superseded-operation hazard guarded
      // elsewhere in this project.
      if (pending == null || frame.cmd != _pendingCmd) continue;
      if (!pending.isCompleted) pending.complete(frame);
    }
  }

  void _onLinkLost() {
    _connected = false;
    _deviceMode = null;
    _failPending(const CardReadException('The Chameleon link dropped'));
  }

  void _failPending(Object error) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  void _throwForStatus(int cmd, int status) {
    if (status == ChameleonStatus.hfTagOk ||
        status == ChameleonStatus.success) {
      return;
    }
    if (status == ChameleonStatus.mfErrAuth) {
      // A foreign card — a user situation, not a fault. Callers must be able
      // to tell this apart, so it gets its own type.
      throw const CardAuthException(
        'Authentication failed — the sector uses a non-factory key',
      );
    }
    throw CardReadException(
      'Chameleon command $cmd failed with status '
      '0x${status.toRadixString(16).padLeft(2, '0')}',
    );
  }
}
