import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/log/logger.dart';
import 'package:nfc_archiver/core/providers/dev_options_provider.dart';
import 'package:nfc_archiver/features/archive/data/archive_repository.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/nfc/presentation/providers/reader_provider.dart';
import 'package:nfc_archiver/features/photo/data/photo_temp.dart';
import 'package:nfc_archiver/features/photo/data/platform_jpeg_session.dart';
import 'package:nfc_archiver/features/photo/domain/photo_fit.dart';
import 'package:nfc_archiver/features/photo/presentation/photo_optimiser_provider.dart';
import 'package:nfc_archiver/features/photo/presentation/photo_optimiser_screen.dart';
import 'package:nfc_archiver/l10n/app_localizations.dart';

import 'support/fake_jpeg_session.dart';

/// Numbers used throughout (NTAG216: 812 B payload per tag; the output name
/// `IMG_1.jpg` costs an 11-byte wrapper; 44 B are reserved for encryption):
///
/// * size(side, q) = side * q / 10, so 640 px / q70 is 4,480 B and needs
///   6 tags (4,480 + 55 > 5 * 812);
/// * the original (5,000 B named `IMG_1.HEIC`) needs 7 tags: the cap;
/// * 6 tags = 4,817 B budget: best fit 800 px, q60 (4,800 B);
/// * 7 tags = 5,629 B budget: best fit 1024 px, q54 (5,529 B).
int linear(int side, int q) => side * q ~/ 10;

const original =
    PendingPhoto(path: '/photos/IMG_1.HEIC', name: 'IMG_1.HEIC', size: 5000);

class _SlowSession extends FakeJpegSession {
  _SlowSession(super.width, super.height, {required super.size});

  @override
  Future<Uint8List> encode({required int maxSide, required int quality}) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return super.encode(maxSide: maxSide, quality: quality);
  }
}

/// Stands in for the 4K developer switch, so a test can flip it mid-screen.
final fake4k = StateProvider<bool>((_) => false);

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('photo_opt_test');
    log.mirrorToConsole = false;
    log.clear();
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
    log.mirrorToConsole = true;
  });

  bool photoErrorLogged() => log
      .snapshot()
      .any((e) => e.level == LogLevel.error && e.scope == 'photo');

  ProviderContainer container({
    PendingPhoto photo = original,
    Future<JpegEncoderSession> Function(String path)? opener,
    JpegEncoderSession? session,
    bool mifareAvailable = false,
    bool mifare4k = false,
    NfcTagType tagType = NfcTagType.ntag216,
  }) {
    final s = session ?? FakeJpegSession(4000, 3000, size: linear);
    final c = ProviderContainer(overrides: [
      pendingPhotoProvider.overrideWith((ref) => photo),
      jpegSessionOpenerProvider.overrideWithValue(opener ?? (_) async => s),
      photoTempDirProvider.overrideWithValue(() async => temp),
      mifareClassicAvailableProvider
          .overrideWith((ref) async => mifareAvailable),
      mifare4kEnabledProvider.overrideWith((ref) => ref.watch(fake4k)),
    ]);
    addTearDown(c.dispose);
    c.read(fake4k.notifier).state = mifare4k;
    c.read(selectedTagTypeProvider.notifier).state = tagType;
    return c;
  }

  Future<void> pumpScreen(WidgetTester tester, ProviderContainer c,
      {Size size = const Size(800, 1600), double textScale = 1.0}) async {
    final router = GoRouter(
      initialLocation: '/archive/optimise',
      routes: [
        GoRoute(
          path: '/archive',
          builder: (_, __) => const Text('picker-page'),
          routes: [
            GoRoute(
                path: 'optimise',
                builder: (_, __) => const PhotoOptimiserScreen()),
            GoRoute(
                path: 'settings',
                builder: (_, __) => const Text('settings-page')),
          ],
        ),
      ],
    );
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await settle(tester);
  }

  Finder tagCount(int n) => find.descendant(
      of: find.byKey(const Key('photoTagCount')),
      matching: find.text('$n'),
      matchRoot: true);

  FilledButton continueButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(find.text('Continue'));
    // The optimised file is written with real I/O: each step completes
    // outside fake async, and its continuation runs on the next pump.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await settle(tester);
  }

  testWidgets('opens with the 640 px / q70 tag count, in auto mode',
      (tester) async {
    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(session: s);
    await pumpScreen(tester, c);

    expect(s.calls.first, (maxSide: 640, quality: 70));
    expect(tagCount(6), findsOneWidget);
    expect(c.read(photoOptimiserProvider).mode, PhotoMode.auto);
    expect(find.text('Back to auto'), findsNothing);
    expect(find.text('800×600 · q60 · 4.7 KB'), findsOneWidget);
    expect(find.text('Best fit: 800 px, quality 60'), findsOneWidget);
  });

  testWidgets('"+" re-fits with a larger budget and updates the label',
      (tester) async {
    final c = container();
    await pumpScreen(tester, c);

    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);

    expect(tagCount(7), findsOneWidget);
    expect(find.text('1024×768 · q54 · 5.4 KB'), findsOneWidget);
  });

  testWidgets('stepper changes are debounced by 250 ms', (tester) async {
    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(session: s);
    await pumpScreen(tester, c);
    final before = s.calls.length;

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump(const Duration(milliseconds: 200));
    expect(s.calls.length, before, reason: 'no encode inside the debounce');
    expect(continueButton(tester).onPressed, isNull,
        reason: 'Continue waits for the re-fit');

    await settle(tester);
    expect(tagCount(4), findsOneWidget);
    // 4 tags = 3,193 B: 640 px misses q50 (3,200 B), so 480 px, q66.
    expect(find.text('480×360 · q66 · 3.1 KB'), findsOneWidget);
  });

  testWidgets('a stale re-fit is dropped', (tester) async {
    final s = _SlowSession(4000, 3000, size: linear);
    final c = container(session: s);
    await pumpScreen(tester, c);
    final shown = <int?>[];
    c.listen(photoOptimiserProvider, (_, n) => shown.add(n.result?.maxSide));

    await tester.tap(find.byIcon(Icons.add)); // 7 tags
    await tester.pump(const Duration(milliseconds: 400)); // fit under way
    await tester.tap(find.byIcon(Icons.remove)); // back to 6
    await settle(tester);

    expect(tagCount(6), findsOneWidget);
    expect(find.text('800×600 · q60 · 4.7 KB'), findsOneWidget);
    expect(c.read(photoOptimiserProvider).result!.maxSide, 800);
    expect(shown, isNot(contains(1024)),
        reason: 'the 7-tag result was superseded and must never show');
  });

  testWidgets('picking another tag type re-fits; Continue keeps it',
      (tester) async {
    final c = container();
    await pumpScreen(tester, c);

    await tester.tap(find.widgetWithText(ChoiceChip, 'NTAG215'));
    await settle(tester);

    // 6 NTAG215 tags = 2,513 B: 480 px, q52.
    expect(find.text('480×360 · q52 · 2.4 KB'), findsOneWidget);
    await tapContinue(tester);
    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag215);
  });

  testWidgets('the slider switches to manual; Back to auto restores auto',
      (tester) async {
    final c = container();
    await pumpScreen(tester, c);

    await tester.drag(find.byType(Slider), const Offset(-200, 0));
    await settle(tester);

    final st = c.read(photoOptimiserProvider);
    expect(st.mode, PhotoMode.manual);
    expect(st.result!.quality, isNot(60));
    expect(find.text('800×600 · q60 · 4.7 KB'), findsNothing);
    expect(find.text('Back to auto'), findsOneWidget);

    await tester.tap(find.text('Back to auto'));
    await settle(tester);

    expect(c.read(photoOptimiserProvider).mode, PhotoMode.auto);
    expect(find.text('800×600 · q60 · 4.7 KB'), findsOneWidget);
    expect(find.text('Back to auto'), findsNothing);
  });

  testWidgets('Continue archives the .jpg and turns compression off',
      (tester) async {
    final c = container();
    c.read(compressionEnabledProvider.notifier).state = true;
    await pumpScreen(tester, c);

    await tapContinue(tester);

    final a = c.read(archiveProvider) as ArchiveFileSelected;
    expect(a.fileName, 'IMG_1.jpg');
    expect(a.fileSize, 4800);
    expect(a.filePath, '${temp.path}/photo_optimiser/IMG_1.jpg');
    expect(File(a.filePath).lengthSync(), 4800);
    expect(c.read(compressionEnabledProvider), isFalse);
    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag216);
    expect(find.text('settings-page'), findsOneWidget);
  });

  testWidgets('the encryption reserve keeps the shown tag count',
      (tester) async {
    final c = container();
    await pumpScreen(tester, c);
    await tapContinue(tester);

    final a = c.read(archiveProvider) as ArchiveFileSelected;
    final estimate = ArchiveRepository.instance.estimateFromSize(
      dataSize: a.fileSize,
      fileName: a.fileName,
      tagType: NfcTagType.ntag216,
      encrypt: true,
      compress: false,
    );
    expect(estimate.chunksNeeded, lessThanOrEqualTo(6));
  });

  testWidgets('Skip archives the original and leaves compression alone',
      (tester) async {
    final c = container();
    c.read(compressionEnabledProvider.notifier).state = true;
    await pumpScreen(tester, c);
    await tester.tap(find.widgetWithText(ChoiceChip, 'NTAG215'));
    await settle(tester);

    await tester.tap(find.text('Skip (keep original)'));
    await settle(tester);

    final a = c.read(archiveProvider) as ArchiveFileSelected;
    expect(a.filePath, '/photos/IMG_1.HEIC');
    expect(a.fileName, 'IMG_1.HEIC');
    expect(a.fileSize, 5000);
    expect(c.read(compressionEnabledProvider), isTrue);
    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag215);
    expect(find.text('settings-page'), findsOneWidget);
  });

  testWidgets('an undecodable photo offers Skip only', (tester) async {
    final c =
        container(opener: (_) async => throw const PhotoDecodeException());
    await pumpScreen(tester, c);

    expect(
        find.text(
            "This photo can't be read here. Use Skip to archive the original file."),
        findsOneWidget);
    expect(continueButton(tester).onPressed, isNull);
    expect(
        tester
            .widget<TextButton>(
                find.widgetWithText(TextButton, 'Skip (keep original)'))
            .onPressed,
        isNotNull);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(photoErrorLogged(), isTrue);
  });

  testWidgets('a platform failure shows the localized message, not its text',
      (tester) async {
    final c = container(
        opener: (_) async => throw PlatformException(
            code: 'encode_failed', message: 'secret-detail'));
    await pumpScreen(tester, c);

    expect(
        find.text(
            "This photo can't be read here. Use Skip to archive the original file."),
        findsOneWidget);
    expect(find.textContaining('secret-detail'), findsNothing);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(continueButton(tester).onPressed, isNull);
    expect(photoErrorLogged(), isTrue);
  });

  testWidgets('a budget that cannot fit says how many tags are needed',
      (tester) async {
    // Every encode is 100,000 B: 124 tags. The 50,000 B original caps at 62.
    final c = container(
      photo: const PendingPhoto(
          path: '/photos/big.png', name: 'IMG_1.png', size: 50000),
      session: FakeJpegSession(4000, 3000, size: (_, __) => 100000),
    );
    await pumpScreen(tester, c);

    expect(tagCount(62), findsOneWidget);
    expect(find.text("Doesn't fit in 62 tags — needs at least 124 tags"),
        findsOneWidget);
    expect(continueButton(tester).onPressed, isNotNull,
        reason: 'Continue stays on the smallest result');
  });

  testWidgets('the stepper is clamped to [1, cap]', (tester) async {
    final c = container();
    await pumpScreen(tester, c);

    await tester.tap(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);
    expect(tagCount(7), findsOneWidget, reason: 'the original needs 7');

    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byIcon(Icons.remove));
    }
    await settle(tester);
    expect(tagCount(1), findsOneWidget);
  });

  testWidgets('the cap never exceeds the NFAR maximum of 65,535 tags',
      (tester) async {
    // 100 MB on NTAG213 would need far more than 65,535 tags.
    final c = container(
      photo: const PendingPhoto(
          path: '/photos/huge.png', name: 'IMG_1.png', size: 100000000),
      tagType: NfcTagType.ntag213,
    );
    c.listen(photoOptimiserProvider, (_, __) {}); // keeps it alive
    await settle(tester);
    expect(c.read(photoOptimiserProvider).cap, NfarLimits.maxChunks);
    c.read(photoOptimiserProvider.notifier).setTags(100000);
    await settle(tester);
    expect(c.read(photoOptimiserProvider).tags, NfarLimits.maxChunks);
  });

  testWidgets('the tag count carries a hint that it can be typed',
      (tester) async {
    final handle = tester.ensureSemantics();
    final c = container();
    await pumpScreen(tester, c);
    expect(
      tester.getSemantics(find.byKey(const Key('photoTagCount'))),
      matchesSemantics(
        label: '6',
        hint: 'Double-tap to type the number',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });

  bool chipSelected(WidgetTester tester, String label) => tester
      .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
      .selected;

  testWidgets(
      '4K with the switch off and no Mifare reader falls back to '
      'NTAG216, and the count holds', (tester) async {
    final c = container(tagType: NfcTagType.mifareClassic4k);
    await pumpScreen(tester, c);

    expect(find.widgetWithText(ChoiceChip, 'Mifare Classic 4K'), findsNothing);
    expect(chipSelected(tester, 'NTAG216'), isTrue);
    expect(c.read(photoOptimiserProvider).tagType, NfcTagType.ntag216);
    expect(tagCount(6), findsOneWidget);
    expect(find.text('800×600 · q60 · 4.7 KB'), findsOneWidget);

    await tapContinue(tester);
    expect(c.read(selectedTagTypeProvider), NfcTagType.ntag216);
    final a = c.read(archiveProvider) as ArchiveFileSelected;
    final estimate = ArchiveRepository.instance.estimateFromSize(
      dataSize: a.fileSize,
      fileName: a.fileName,
      tagType: NfcTagType.ntag216,
      encrypt: true,
      compress: false,
    );
    expect(estimate.chunksNeeded, lessThanOrEqualTo(6));
  });

  testWidgets('4K with the switch off and a Mifare reader falls back to 1K',
      (tester) async {
    final c =
        container(tagType: NfcTagType.mifareClassic4k, mifareAvailable: true);
    await pumpScreen(tester, c);

    expect(chipSelected(tester, 'Mifare Classic 1K'), isTrue);
    // 1K: 720 B per tag. 640 px / q70 needs 7 tags = 4,985 B: 800 px, q62.
    expect(tagCount(7), findsOneWidget);
    expect(find.text('800×600 · q62 · 4.8 KB'), findsOneWidget);

    await tapContinue(tester);
    expect(c.read(selectedTagTypeProvider), NfcTagType.mifareClassic1k);
    final a = c.read(archiveProvider) as ArchiveFileSelected;
    final estimate = ArchiveRepository.instance.estimateFromSize(
      dataSize: a.fileSize,
      fileName: a.fileName,
      tagType: NfcTagType.mifareClassic1k,
      encrypt: true,
      compress: false,
    );
    expect(estimate.chunksNeeded, lessThanOrEqualTo(7));
  });

  testWidgets('turning the 4K switch off while open re-fits for 1K',
      (tester) async {
    final c = container(
        tagType: NfcTagType.mifareClassic4k,
        mifareAvailable: true,
        mifare4k: true);
    await pumpScreen(tester, c);
    expect(chipSelected(tester, 'Mifare Classic 4K'), isTrue);

    c.read(fake4k.notifier).state = false;
    await settle(tester);

    expect(chipSelected(tester, 'Mifare Classic 1K'), isTrue);
    expect(c.read(photoOptimiserProvider).tagType, NfcTagType.mifareClassic1k);
    expect(c.read(photoOptimiserProvider).busy, isFalse);
  });

  for (final size in const [Size(390, 844), Size(320, 568)]) {
    for (final scale in const [1.0, 2.0]) {
      testWidgets(
          'at ${size.width.toInt()}×${size.height.toInt()}, text ×$scale, '
          'Continue is on screen and works', (tester) async {
        final c = container();
        await pumpScreen(tester, c, size: size, textScale: scale);

        expect(tester.takeException(), isNull, reason: 'no overflow');
        final button = find.text('Continue');
        expect(button.hitTestable(), findsOneWidget);
        final screen = Offset.zero & size;
        final rect = tester.getRect(button);
        expect(
            screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
            isTrue,
            reason: 'Continue at $rect must lie inside $screen');

        await tapContinue(tester);
        expect(c.read(archiveProvider), isA<ArchiveFileSelected>());
        expect(find.text('settings-page'), findsOneWidget);
      });
    }
  }

  /// 32,000 B named `IMG_1.HEIC` needs 40 NTAG216 tags: the cap.
  const big =
      PendingPhoto(path: '/photos/IMG_1.HEIC', name: 'IMG_1.HEIC', size: 32000);

  testWidgets('holding "+" runs to the cap and fits once after release',
      (tester) async {
    // The encodes a direct jump to 40 tags costs, for comparison.
    final ref = FakeJpegSession(4000, 3000, size: linear);
    final rc = container(photo: big, session: ref);
    rc.listen(photoOptimiserProvider, (_, __) {}); // keeps it alive
    await settle(tester);
    final refBefore = ref.calls.length;
    rc.read(photoOptimiserProvider.notifier).setTags(40);
    await settle(tester);
    final oneFit = ref.calls.length - refBefore;
    expect(oneFit, greaterThan(0));

    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(photo: big, session: s);
    await pumpScreen(tester, c);
    expect(c.read(photoOptimiserProvider).cap, 40);
    expect(tagCount(6), findsOneWidget);
    final before = s.calls.length;

    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(s.calls.length, before, reason: 'no fit while held');
    expect(c.read(photoOptimiserProvider).tags, greaterThan(6),
        reason: 'the count moves on screen while held');
    await tester.pump(const Duration(milliseconds: 2000));
    expect(tagCount(40), findsOneWidget);
    expect(s.calls.length, before, reason: 'no fit while held');
    expect(continueButton(tester).onPressed, isNull,
        reason: 'Continue waits for the fit');

    await g.up();
    await settle(tester);
    expect(tagCount(40), findsOneWidget);
    expect(s.calls.length - before, oneFit, reason: 'one fit after release');
    expect(continueButton(tester).onPressed, isNotNull);
  });

  testWidgets('a stepper removed mid-hold ends the hold; later steps re-fit',
      (tester) async {
    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(photo: big, session: s);
    c.listen(photoOptimiserProvider, (_, __) {}); // outlives the widgets
    await pumpScreen(tester, c);

    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(c.read(photoOptimiserProvider).busy, isTrue);

    // The stepper goes away while the finger is still down.
    await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()));
    await settle(tester);
    await g.up();
    expect(c.read(photoOptimiserProvider).busy, isFalse,
        reason: 'the hold ended, so the fit ran');

    final before = s.calls.length;
    c.read(photoOptimiserProvider.notifier).setTags(20);
    await settle(tester);
    expect(s.calls.length, greaterThan(before), reason: 'a later step re-fits');
    expect(c.read(photoOptimiserProvider).busy, isFalse);
  });

  testWidgets('endHold after the notifier is gone does nothing',
      (tester) async {
    final c = container(photo: big);
    final sub = c.listen(photoOptimiserProvider, (_, __) {});
    await settle(tester);
    final notifier = c.read(photoOptimiserProvider.notifier);
    notifier.beginHold();
    sub.close();
    await settle(tester); // the auto-dispose runs
    expect(c.exists(photoOptimiserProvider), isFalse);
    notifier.endHold(); // must not touch a disposed StateNotifier
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  Future<void> enterCount(WidgetTester tester, String text,
      {bool ok = true}) async {
    await tester.tap(find.byKey(const Key('photoTagCount')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text(ok ? 'OK' : 'Cancel'));
    await settle(tester);
  }

  testWidgets('typing the count sets it and re-fits', (tester) async {
    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(photo: big, session: s);
    await pumpScreen(tester, c);
    final before = s.calls.length;

    await enterCount(tester, '25');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tagCount(25), findsOneWidget);
    expect(s.calls.length, greaterThan(before), reason: 're-fit');
    expect(c.read(photoOptimiserProvider).busy, isFalse);
  });

  testWidgets('a typed count is clamped to [1, cap]', (tester) async {
    final c = container(photo: big);
    await pumpScreen(tester, c);

    await enterCount(tester, '0');
    expect(tagCount(1), findsOneWidget);
    await enterCount(tester, '999');
    expect(tagCount(40), findsOneWidget);
  });

  testWidgets('empty input or Cancel leaves the count alone', (tester) async {
    final c = container(photo: big);
    await pumpScreen(tester, c);

    await enterCount(tester, '');
    expect(tagCount(6), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await enterCount(tester, '12', ok: false);
    expect(tagCount(6), findsOneWidget);
  });

  const largerHint = 'The original file is smaller — Skip keeps it.';

  testWidgets('says so when the optimised photo outgrows the original',
      (tester) async {
    // Every encode is 3,000 B; the original is 2,000 B.
    final c = container(
      photo: const PendingPhoto(
          path: '/photos/small.jpg', name: 'IMG_1.jpg', size: 2000),
      session: FakeJpegSession(270, 480, size: (_, __) => 3000),
    );
    await pumpScreen(tester, c);
    expect(find.text(largerHint), findsOneWidget);
  });

  testWidgets('no hint when the optimised photo is smaller', (tester) async {
    final c = container();
    await pumpScreen(tester, c);
    expect(find.text('800×600 · q60 · 4.7 KB'), findsOneWidget);
    expect(find.text(largerHint), findsNothing);
  });

  testWidgets('leaving the screen closes the session', (tester) async {
    final s = FakeJpegSession(4000, 3000, size: linear);
    final c = container(session: s);
    await pumpScreen(tester, c);

    // Navigate away; the provider scope stays, as in the app.
    await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()));
    await settle(tester);
    expect(c.exists(photoOptimiserProvider), isFalse);
    expect(s.closed, isTrue);
  });
}

/// Lets debounce timers and fake-async encodes run out. Not pumpAndSettle:
/// the busy indicator animates.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
