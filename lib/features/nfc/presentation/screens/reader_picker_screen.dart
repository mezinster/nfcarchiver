import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../inspect/presentation/screens/inspect_dialog.dart';
import '../../data/ble_scanner.dart';
import '../providers/reader_provider.dart';

/// Choose between the phone's own NFC radio and a Chameleon Ultra.
///
/// The phone entry is always present and always works. The Chameleon entry
/// scans live, and every failure — Bluetooth off, permission refused, nothing
/// found — says which it was: an empty list with no explanation leaves the user
/// concluding their reader is broken.
class ReaderPickerScreen extends ConsumerStatefulWidget {
  const ReaderPickerScreen({super.key, this.scanner});

  /// Injectable so widget tests can drive discovery without a radio.
  final BleScanner? scanner;

  @override
  ConsumerState<ReaderPickerScreen> createState() => _ReaderPickerScreenState();
}

class _ReaderPickerScreenState extends ConsumerState<ReaderPickerScreen> {
  late final BleScanner _scanner = widget.scanner ?? BleScanner();

  StreamSubscription<DiscoveredReader>? _sub;
  final List<DiscoveredReader> _found = [];
  bool _scanning = false;
  bool _connecting = false;
  BleUnavailableReason? _unavailable;

  @override
  void dispose() {
    // A scan left running after the screen closes keeps the radio busy and
    // drains the battery for a UI nobody is looking at.
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _found.clear();
      _unavailable = null;
      _scanning = true;
    });
    try {
      await _scanner.ensurePermissions();
      if (!await _scanner.isBluetoothReady()) {
        throw const BleUnavailableException(BleUnavailableReason.bluetoothOff);
      }
      _sub = _scanner.scan().listen((d) {
        if (!mounted) return;
        setState(() {
          // Advertisements repeat; keep one entry per device.
          final i = _found.indexWhere((e) => e.id == d.id);
          if (i >= 0) {
            _found[i] = d;
          } else {
            _found.add(d);
          }
        });
      });
    } on BleUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _unavailable = e.reason;
      });
    }
  }

  Future<void> _connect(DiscoveredReader device) async {
    setState(() => _connecting = true);
    await _sub?.cancel();
    await ref
        .read(readerControllerProvider.notifier)
        .select(ReaderKind.chameleon, deviceId: device.id);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _scanning = false;
    });
    final state = ref.read(readerControllerProvider);
    if (state.isConnected) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final reader = ref.watch(readerControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.readerTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.nfc),
              title: Text(l10n.readerPhoneNfc),
              subtitle: Text(l10n.readerPhoneSubtitle),
              trailing: reader.kind == ReaderKind.phone
                  ? const Icon(Icons.check_circle)
                  : null,
              onTap: () async {
                await ref
                    .read(readerControllerProvider.notifier)
                    .select(ReaderKind.phone);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(l10n.readerChameleon),
                  subtitle: Text(l10n.readerChameleonSubtitle),
                  trailing: reader.kind == ReaderKind.chameleon
                      ? const Icon(Icons.check_circle)
                      : null,
                ),
                if (reader.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l10n.readerConnectFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_unavailable != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      switch (_unavailable!) {
                        BleUnavailableReason.permissionDenied =>
                          l10n.readerPermissionDenied,
                        BleUnavailableReason.bluetoothOff =>
                          l10n.readerBluetoothOff,
                        BleUnavailableReason.unsupported =>
                          l10n.readerBluetoothOff,
                      },
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_connecting)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.readerConnecting),
                  )
                else if (!_scanning)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: OutlinedButton.icon(
                      onPressed: _startScan,
                      icon: const Icon(Icons.search),
                      label: Text(l10n.readerSearch),
                    ),
                  ),
                if (_scanning && _found.isEmpty && _unavailable == null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.readerScanning),
                  ),
                for (final d in _found)
                  ListTile(
                    leading: const Icon(Icons.memory),
                    title: Text(d.name),
                    subtitle: Text('${d.id}  ·  ${d.rssi} dBm'),
                    onTap: _connecting ? null : () => _connect(d),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Visible but DISABLED under phone NFC, never hidden: a silently
          // absent control teaches the user nothing, whereas a disabled one
          // with a reason explains a permanent platform limit.
          Tooltip(
            message: reader.reader.supportsRawAccess
                ? ''
                : l10n.inspectNeedsChameleon,
            child: OutlinedButton.icon(
              onPressed: reader.reader.rawDevice == null
                  ? null
                  : () {
                      // The reader's OWN device, never a fresh one: a second
                      // instance is not subscribed to notifications and every
                      // command it sends times out.
                      final dev = reader.reader.rawDevice!;
                      reader.reader.stopSession();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => InspectDialog(
                            device: dev,
                            uid: (reader.deviceId ?? 'card').replaceAll(':', ''),
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.travel_explore),
              label: Text(l10n.inspectTitle),
            ),
          ),
          if (reader.kind == ReaderKind.chameleon) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () =>
                  ref.read(readerControllerProvider.notifier).disconnect(),
              icon: const Icon(Icons.link_off),
              label: Text(l10n.readerDisconnect),
            ),
          ],
        ],
      ),
    );
  }
}
