import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/data/ble_scanner.dart';
import 'package:nfc_archiver/features/nfc/presentation/screens/reader_picker_screen.dart';

/// A scanner that never touches a radio.
class _FakeScanner implements BleScanner {
  _FakeScanner({this.devices = const [], this.failWith, this.ready = true});

  final List<DiscoveredReader> devices;
  final BleUnavailableReason? failWith;
  final bool ready;

  @override
  Future<void> ensurePermissions() async {
    if (failWith == BleUnavailableReason.permissionDenied) {
      throw const BleUnavailableException(BleUnavailableReason.permissionDenied);
    }
  }

  @override
  Future<bool> isBluetoothReady() async => ready;

  @override
  Stream<DiscoveredReader> scan() => Stream.fromIterable(devices);
}

Widget _host(BleScanner scanner) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ReaderPickerScreen(scanner: scanner),
      ),
    );

void main() {
  testWidgets('the phone reader is always offered and marked active',
      (t) async {
    await t.pumpWidget(_host(_FakeScanner()));
    await t.pumpAndSettle();
    expect(find.text('Phone NFC'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget,
        reason: 'the phone radio is active by default');
  });

  testWidgets('discovered Chameleons are listed with id and signal', (t) async {
    await t.pumpWidget(_host(_FakeScanner(devices: const [
      DiscoveredReader(id: 'AA:BB:CC', name: 'ChameleonUltra', rssi: -55),
    ])));
    await t.pumpAndSettle();
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(find.text('ChameleonUltra'), findsOneWidget);
    expect(find.textContaining('-55 dBm'), findsOneWidget);
  });

  testWidgets('a refused permission is explained, not shown as an empty list',
      (t) async {
    // An empty list with no reason leaves the user concluding their reader is
    // broken, when in fact the app simply was not allowed to look.
    await t.pumpWidget(_host(
      _FakeScanner(failWith: BleUnavailableReason.permissionDenied),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(
      find.text('Bluetooth permission is required to find a Chameleon.'),
      findsOneWidget,
    );
  });

  testWidgets('Bluetooth being off is named specifically', (t) async {
    await t.pumpWidget(_host(_FakeScanner(ready: false)));
    await t.pumpAndSettle();
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(
      find.text('Bluetooth is off. Turn it on to use a Chameleon.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty scan says so rather than showing nothing', (t) async {
    await t.pumpWidget(_host(_FakeScanner()));
    await t.pumpAndSettle();
    await t.tap(find.text('Search'));
    await t.pump();
    expect(find.text('Searching for Chameleons…'), findsOneWidget);
  });
}
