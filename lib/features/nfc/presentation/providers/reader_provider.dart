import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/chameleon/ble_chameleon_device.dart';
import '../../data/chameleon_reader.dart';
import '../../data/phone_nfc_reader.dart';
import '../../domain/card_reader.dart';
import 'nfc_provider.dart';

enum ReaderKind { phone, chameleon }

class ReaderState {
  const ReaderState({
    required this.reader,
    required this.kind,
    required this.isConnected,
    this.deviceId,
    this.error,
  });

  final CardReader reader;
  final ReaderKind kind;
  final bool isConnected;
  final String? deviceId;
  final String? error;

  ReaderState copyWith({
    CardReader? reader,
    ReaderKind? kind,
    bool? isConnected,
    String? deviceId,
    String? error,
  }) =>
      ReaderState(
        reader: reader ?? this.reader,
        kind: kind ?? this.kind,
        isConnected: isConnected ?? this.isConnected,
        deviceId: deviceId ?? this.deviceId,
        error: error,
      );
}

/// Owns which reader is active, and guarantees there is exactly one.
///
/// `nfc_manager` and `flutter_reactive_ble` both claim hardware, so two active
/// readers is not merely untidy — it is a leaked session. Every switch
/// therefore tears the outgoing reader down **first**, mirroring
/// `teardownActiveReader()` in the web app's `device.ts`.
class ReaderController extends StateNotifier<ReaderState> {
  ReaderController({
    required CardReader Function() makePhone,
    required CardReader Function(String deviceId) makeChameleon,
  })  : _makePhone = makePhone,
        _makeChameleon = makeChameleon,
        super(ReaderState(
          reader: makePhone(),
          kind: ReaderKind.phone,
          isConnected: false,
        ));

  final CardReader Function() _makePhone;
  final CardReader Function(String deviceId) _makeChameleon;

  /// Switch readers. [deviceId] is required for [ReaderKind.chameleon].
  Future<void> select(ReaderKind kind, {String? deviceId}) async {
    await _teardown();

    if (kind == ReaderKind.phone) {
      state = ReaderState(
        reader: _makePhone(),
        kind: ReaderKind.phone,
        isConnected: false,
      );
      return;
    }

    if (deviceId == null) {
      throw ArgumentError('A Chameleon needs a device id');
    }

    final next = _makeChameleon(deviceId);
    try {
      await next.connect();
    } catch (e) {
      // The web app's failHandOff lesson: a connect that fails AFTER teardown
      // would otherwise leave the UI reading "connected", with every listener
      // still believing it — a real true->false transition that fires no
      // callbacks. Tear the half-open session down and fall back explicitly to
      // the radio that is always there.
      try {
        await next.disconnect();
      } catch (_) {
        // Already dead; nothing to salvage.
      }
      state = ReaderState(
        reader: _makePhone(),
        kind: ReaderKind.phone,
        isConnected: false,
        error: e.toString(),
      );
      return;
    }

    state = ReaderState(
      reader: next,
      kind: ReaderKind.chameleon,
      isConnected: true,
      deviceId: deviceId,
    );
  }

  /// Drop the active reader and return to the phone radio.
  Future<void> disconnect() async {
    await _teardown();
    state = ReaderState(
      reader: _makePhone(),
      kind: ReaderKind.phone,
      isConnected: false,
    );
  }

  Future<void> _teardown() async {
    try {
      await state.reader.disconnect();
    } catch (_) {
      // A reader that is already gone must never block the switch to the next
      // one — the whole point of tearing down first.
    }
  }
}

final readerControllerProvider =
    StateNotifierProvider<ReaderController, ReaderState>((ref) {
  final controller = ReaderController(
    makePhone: PhoneNfcReader.new,
    makeChameleon: (deviceId) =>
        ChameleonReader(BleChameleonDevice(deviceId: deviceId)),
  );
  // Keep the seam every card operation reads in step with the selection. This
  // is the single wire between choosing a reader and using one.
  controller.addListener((s) {
    ref.read(activeReaderProvider.notifier).state = s.reader;
  });
  return controller;
});
