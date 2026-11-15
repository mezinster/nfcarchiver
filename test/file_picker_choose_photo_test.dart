import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/archive/presentation/screens/file_picker_screen.dart';
import 'package:nfc_archiver/features/photo/presentation/photo_optimiser_provider.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

/// Only [name] and [uri] (hence `path`) are read by the screen.
final class _Picked extends PlatformFile {
  _Picked(File file)
      : name = file.uri.pathSegments.last,
        uri = file.uri;

  @override
  final String name;
  @override
  final Uri uri;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the requested type and answers with [result].
class _FakePicker extends FilePickerPlatform {
  final types = <FileType>[];
  List<PlatformFile> result = const [];

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    types.add(type);
    return result;
  }
}

/// "Choose photo" asks the system for images only — the route that needs no
/// photo-library permission — and sends the pick to the optimiser. The file
/// card keeps asking for any file.
void main() {
  late Directory dir;
  late _FakePicker picker;
  late FilePickerPlatform realPicker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('choose_photo');
    realPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker = _FakePicker();
  });
  tearDown(() {
    FilePickerPlatform.instance = realPicker;
    dir.deleteSync(recursive: true);
  });

  Future<(ProviderContainer, GoRouter)> pump(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = GoRouter(initialLocation: '/archive', routes: [
      GoRoute(path: '/archive', builder: (_, __) => const FilePickerScreen()),
      GoRoute(
          path: '/archive/optimise',
          builder: (_, __) => const Text('optimise-page')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
    return (container, router);
  }

  // The pick awaits real file I/O (the size), which the fake clock never ends.
  Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Choose photo asks for images and opens the optimiser',
      (tester) async {
    // No image extension: what makes it a photo is the button it came from.
    final file = File('${dir.path}/IMG_0001')..writeAsBytesSync(List.filled(64, 1));
    picker.result = [_Picked(file)];
    final (container, _) = await pump(tester);

    await tapAndSettle(tester, find.text('Choose photo'));

    expect(picker.types, [FileType.image]);
    expect(find.text('optimise-page'), findsOneWidget);
    final pending = container.read(pendingPhotoProvider);
    expect(pending?.path, file.path);
    expect(pending?.size, 64);
  });

  testWidgets('the file card asks for any file and stays on the screen',
      (tester) async {
    final file = File('${dir.path}/notes.txt')..writeAsBytesSync(List.filled(10, 1));
    picker.result = [_Picked(file)];
    final (container, _) = await pump(tester);

    await tapAndSettle(tester, find.text('Tap to select a file'));

    expect(picker.types, [FileType.any]);
    expect(find.text('optimise-page'), findsNothing);
    expect(container.read(archiveProvider), isA<ArchiveFileSelected>());
  });

  testWidgets('a cancelled photo pick changes nothing', (tester) async {
    final (container, _) = await pump(tester);

    await tapAndSettle(tester, find.text('Choose photo'));

    expect(picker.types, [FileType.image]);
    expect(find.text('optimise-page'), findsNothing);
    expect(container.read(pendingPhotoProvider), isNull);
    expect(container.read(archiveProvider), isA<ArchiveInitial>());
  });
}
