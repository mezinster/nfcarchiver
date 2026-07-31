import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../log/logger.dart';
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
    log.info('ble', 'Connecting', {'deviceId': deviceId});

    final ready = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
      (update) {
        log.debug('ble', 'GATT state', {'state': update.connectionState.name});
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
        log.error('ble', 'GATT error', {'error': e.toString()});
        if (!ready.isCompleted) ready.completeError(e);
      },
    );

    await ready.future;
    log.info('ble', 'GATT connected; subscribing to notifications');

    _notifySub = _ble.subscribeToCharacteristic(_char(txCharUuid)).listen(
      (bytes) => _onNotification(Uint8List.fromList(bytes)),
      onError: (Object _) => _onLinkLost(),
    );

    _connected = true;
    log.info('ble', 'Switching device to READER mode');

    // The Chameleon boots into EMULATOR mode and silently refuses every HF
    // command until switched. This is invisible from the device seam — the
    // reference hides it inside each command — so it is done once, here, and
    // then asserted by a liveness check rather than left to call sites.
    await _sendCommand(
      ChameleonCmd.changeDeviceMode,
      encodeChangeDeviceMode(ChameleonDeviceMode.reader),
    );
    _deviceMode = ChameleonDeviceMode.reader;
    log.info('ble', 'Reader mode accepted');

    // Proves the link actually carries frames, so a half-open GATT connection
    // fails here rather than at the first card operation.
    final version = await _sendCommand(ChameleonCmd.getAppVersion, Uint8List(0));
    log.info('ble', 'Connected', {'appVersion': hexDump(version.data)});
  }

  @override
  Future<void> disconnect() async {
    log.info('ble', 'Disconnecting', {'deviceId': deviceId});
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
    // HF_TAG_NOT_FOUND is the device's normal answer when nothing is on the
    // reader, so it is an allowed status rather than a failure — polling an
    // empty field is what a reader waiting for a tap does.
    final frame = await _sendCommand(
      ChameleonCmd.hf14aScan,
      Uint8List(0),
      alsoAllow: const {ChameleonStatus.hfTagNotFound},
    );
    if (frame.status == ChameleonStatus.hfTagNotFound) return null;
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
    Set<int> alsoAllow = const {},
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
      final frameBytes = encodeFrame(cmd, data);
      log.debug('frame', 'TX', {
        'cmd': cmd,
        'len': data.length,
        'hex': hexDump(frameBytes),
      });
      await _ble.writeCharacteristicWithoutResponse(
        _char(rxCharUuid),
        value: frameBytes,
      );
      final frame = await completer.future.timeout(
        timeout,
        onTimeout: () => throw TagTimeoutException(
          'The Chameleon did not answer command $cmd within '
          '${timeout.inMilliseconds}ms',
        ),
      );
      _throwForStatus(cmd, frame.status, alsoAllow);
      return frame;
    } finally {
      _pending = null;
      _pendingCmd = null;
    }
  }

  void _onNotification(Uint8List bytes) {
    // Logged BEFORE parsing: if the parser mis-handles real BLE boundaries,
    // the raw notification sizes are the only evidence of what actually
    // arrived.
    log.debug('frame', 'RX notification', {
      'len': bytes.length,
      'hex': hexDump(bytes),
    });
    for (final frame in _parser.feed(bytes)) {
      log.debug('frame', 'RX frame', {
        'cmd': frame.cmd,
        'status': '0x${frame.status.toRadixString(16).padLeft(2, '0')}',
        'len': frame.data.length,
        'data': hexDump(frame.data),
      });
      final pending = _pending;
      // A frame for a command we are not waiting on is stale — most likely the
      // late answer to a command that already timed out. Dropping it is
      // correct: completing the CURRENT waiter with it would answer the wrong
      // question, which is the same superseded-operation hazard guarded
      // elsewhere in this project.
      if (pending == null || frame.cmd != _pendingCmd) {
        log.warn('frame', 'Dropped unmatched frame', {
          'got': frame.cmd,
          'awaiting': _pendingCmd,
        });
        continue;
      }
      if (!pending.isCompleted) pending.complete(frame);
    }
  }

  void _onLinkLost() {
    log.warn('ble', 'Link lost');
    _connected = false;
    _deviceMode = null;
    _failPending(const CardReadException('The Chameleon link dropped'));
  }

  void _failPending(Object error) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  void _throwForStatus(int cmd, int status, Set<int> alsoAllow) {
    // There is no single success value: HF operations answer 0x00, LF 0x40,
    // and device-level commands 0x68. Assuming one is what made the first
    // hardware session fail on a mode change that had actually worked.
    if (ChameleonStatus.okValues.contains(status) ||
        alsoAllow.contains(status)) {
      return;
    }
    log.warn('frame', 'Command failed', {
      'cmd': cmd,
      'status': '0x${status.toRadixString(16).padLeft(2, '0')}',
      'name': ChameleonStatus.describe(status),
    });
    if (status == ChameleonStatus.mfErrAuth) {
      // A foreign card — a user situation, not a fault. Callers must be able
      // to tell this apart, so it gets its own type.
      throw const CardAuthException(
        'Authentication failed — the sector uses a non-factory key',
      );
    }
    throw CardReadException(
      'Chameleon command $cmd failed: ${ChameleonStatus.describe(status)} '
      '(0x${status.toRadixString(16).padLeft(2, '0')})',
    );
  }
}
