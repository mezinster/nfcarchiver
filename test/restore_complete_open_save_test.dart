import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/services/file_actions_service.dart';
import 'package:nfc_archiver/features/restore/data/restore_repository.dart';
import 'package:nfc_archiver/features/restore/presentation/providers/restore_provider.dart';
import 'package:nfc_archiver/features/restore/presentation/screens/restore_progress_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

const _savedPath = '/private/NFC_Archives/report.pdf';

class _CompleteNotifier extends RestoreNotifier {
  _CompleteNotifier() {
    state = RestoreComplete(
      fileName: 'report.pdf',
      result: RestoreResult(
        data: Uint8List.fromList([1, 2, 3]),
        savedPath: _savedPath,
        wasEncrypted: false,
        wasCompressed: false,
        totalChunks: 1,
      ),
    );
  }
}

class _RecordingActions extends FileActionsService {
  final opened = <String>[];
  final exported = <String>[];

  @override
  Future<OpenOutcome> openFile(String filePath) async {
    opened.add(filePath);
    return OpenOutcome.opened;
  }

  @override
  Future<bool> exportFile(String filePath) async {
    exported.add(filePath);
    return true;
  }
}

Widget _host(FileActionsService actions) => ProviderScope(
      overrides: [
        restoreProvider.overrideWith((ref) => _CompleteNotifier()),
        fileActionsProvider.overrideWithValue(actions),
      ],
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: [Locale('en')],
        home: RestoreProgressScreen(),
      ),
    );

void main() {
  testWidgets('a restored file can be opened straight from the result',
      (tester) async {
    final actions = _RecordingActions();
    await tester.pumpWidget(_host(actions));
    await tester.pump();

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(actions.opened, [_savedPath]);
  });

  testWidgets('a restored file can be saved to the device', (tester) async {
    final actions = _RecordingActions();
    await tester.pumpWidget(_host(actions));
    await tester.pump();

    await tester.tap(find.text('Save to device'));
    await tester.pump();

    expect(actions.exported, [_savedPath]);
    expect(find.text('Saved to device'), findsOneWidget);
  });

  testWidgets('share and delete stay available next to the new actions',
      (tester) async {
    await tester.pumpWidget(_host(_RecordingActions()));
    await tester.pump();

    expect(find.text('Share File'), findsOneWidget);
    expect(find.text('Delete File'), findsOneWidget);
  });

  testWidgets('the result still fits a small phone', (tester) async {
    // The complete view is a fixed, unscrollable Column; an extra button row
    // is exactly what overflows it on a short screen.
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_RecordingActions()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
