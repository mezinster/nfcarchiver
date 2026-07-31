import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/features/inspect/presentation/providers/inspect_provider.dart';
import 'package:nfc_archiver/features/inspect/presentation/screens/inspect_dialog.dart';

import 'support/fake_chameleon_device.dart';

late ProviderContainer container;

Widget host(ChameleonDevice device) {
  container = ProviderContainer();
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: InspectDialog(device: device),
    ),
  );
}

void main() {
  testWidgets('a completed inspection shows identity, NFAR and raw rows',
      (t) async {
    await t.pumpWidget(host(FakeChameleonDevice.classic1k()));
    await t.pumpAndSettle();

    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('NFAR chunk'), findsOneWidget);
    expect(find.text('Raw'), findsOneWidget);
    expect(find.textContaining('Mifare Classic 1K'), findsOneWidget);
  });

  testWidgets('rows appear progressively rather than only at the end',
      (t) async {
    // A 64-block dump over BLE is not instant; the dialog must not look frozen
    // while it runs.
    final slow = FakeChameleonDevice.classic1k()
      ..delayPerBlock(const Duration(milliseconds: 3));
    await t.pumpWidget(host(slow));
    await t.pump(const Duration(milliseconds: 40));

    final partial = container.read(inspectProvider).rows.length;
    expect(partial, greaterThan(0));
    expect(partial, lessThan(64), reason: 'still running');

    await t.pumpAndSettle(const Duration(milliseconds: 10));
  });

  testWidgets('Copy puts the report on the clipboard', (t) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });

    await t.pumpWidget(host(FakeChameleonDevice.classic1k()));
    await t.pumpAndSettle();
    await t.tap(find.text('Copy'));
    await t.pumpAndSettle();

    expect(calls.any((c) => c.method == 'Clipboard.setData'), isTrue);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('closing mid-dump cancels the run', (t) async {
    // A dialog dismissed while running must not leave a run polling the reader.
    final slow = FakeChameleonDevice.classic1k()
      ..delayPerBlock(const Duration(milliseconds: 5));
    await t.pumpWidget(host(slow));
    await t.pump(const Duration(milliseconds: 20));
    expect(container.read(inspectProvider).isRunning, isTrue);

    await t.tap(find.text('Close'));
    await t.pump();

    expect(container.read(inspectProvider).isRunning, isFalse);
    await t.pumpAndSettle(const Duration(milliseconds: 10));
  });

  testWidgets('an unsupported tag shows its SPECIFIC message', (t) async {
    await t.pumpWidget(host(FakeChameleonDevice.classic1k()..overrideSak(0x20)));
    await t.pumpAndSettle();
    expect(find.textContaining('20'), findsWidgets);
  });

  testWidgets('an auth-failed block is shown in place, not omitted', (t) async {
    // An unreadable sector is itself diagnostic — hiding it would defeat the
    // point of an inspector.
    final dev = FakeChameleonDevice.classic1k(sectorKeys: {
      for (var s = 0; s < 16; s++)
        s: Uint8List.fromList(const [9, 9, 9, 9, 9, 9]),
    });
    await t.pumpWidget(host(dev));
    await t.pumpAndSettle();
    expect(container.read(inspectProvider).rows.length, 64);
    expect(
      container.read(inspectProvider).rows.any((r) => r.contains('auth failed')),
      isTrue,
    );
  });
}
