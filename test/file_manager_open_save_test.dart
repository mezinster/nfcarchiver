import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/services/file_actions_service.dart';
import 'package:nfc_archiver/features/file_manager/data/file_manager_repository.dart';
import 'package:nfc_archiver/features/file_manager/presentation/providers/file_manager_provider.dart';
import 'package:nfc_archiver/features/file_manager/presentation/screens/file_manager_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Skips the path_provider-backed repository: the screen under test only
/// needs a loaded list.
class _LoadedNotifier extends FileManagerNotifier {
  _LoadedNotifier(super.ref, this._files);

  final List<ArchivedFileInfo> _files;

  @override
  Future<void> loadFiles() async {
    state = FileManagerLoaded(
      files: _files,
      storageInfo: StorageInfo(fileCount: _files.length, totalBytes: 3),
    );
  }
}

final _file = ArchivedFileInfo(
  name: 'notes.txt',
  path: '/private/NFC_Archives/notes.txt',
  size: 3,
  modified: DateTime(2026, 9, 1),
);

Widget _host(FileActionsService actions) => ProviderScope(
      overrides: [
        fileManagerProvider.overrideWith((ref) => _LoadedNotifier(ref, [_file])),
        fileActionsProvider.overrideWithValue(actions),
      ],
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: [Locale('en')],
        home: FileManagerScreen(),
      ),
    );

class _RecordingActions extends FileActionsService {
  _RecordingActions({this.open = OpenOutcome.opened, this.saved = true});

  final OpenOutcome open;
  final bool saved;
  final opened = <String>[];
  final exported = <String>[];

  @override
  Future<OpenOutcome> openFile(String filePath) async {
    opened.add(filePath);
    return open;
  }

  @override
  Future<bool> exportFile(String filePath) async {
    exported.add(filePath);
    return saved;
  }
}

void main() {
  testWidgets('tapping a file opens it', (tester) async {
    final actions = _RecordingActions();
    await tester.pumpWidget(_host(actions));
    await tester.pumpAndSettle();

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(actions.opened, [_file.path]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('says so when no installed app can open the file',
      (tester) async {
    await tester.pumpWidget(_host(_RecordingActions(open: OpenOutcome.noApp)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(find.text('No app installed to open this file'), findsOneWidget);
  });

  testWidgets('reports a failed open', (tester) async {
    await tester.pumpWidget(_host(_RecordingActions(open: OpenOutcome.failed)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Could not open the file'), findsOneWidget);
  });

  testWidgets('the row menu offers open, save, share and delete',
      (tester) async {
    await tester.pumpWidget(_host(_RecordingActions()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Save to device'), findsOneWidget);
    expect(find.text('Share File'), findsOneWidget);
    expect(find.text('Delete File'), findsOneWidget);
  });

  testWidgets('Save to device exports the file and confirms it',
      (tester) async {
    final actions = _RecordingActions();
    await tester.pumpWidget(_host(actions));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to device'));
    await tester.pumpAndSettle();

    expect(actions.exported, [_file.path]);
    expect(find.text('Saved to device'), findsOneWidget);
  });

  testWidgets('a dismissed save picker confirms nothing', (tester) async {
    final actions = _RecordingActions(saved: false);
    await tester.pumpWidget(_host(actions));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to device'));
    await tester.pumpAndSettle();

    expect(actions.exported, [_file.path]);
    expect(find.byType(SnackBar), findsNothing);
  });
}
