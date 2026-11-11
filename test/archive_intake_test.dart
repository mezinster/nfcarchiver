import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/archive/domain/archive_intake.dart';
import 'package:nfc_archiver/features/archive/presentation/providers/archive_provider.dart';
import 'package:nfc_archiver/features/photo/presentation/photo_optimiser_provider.dart';

void main() {
  test('isImageFileName matches image extensions case-insensitively', () {
    expect(isImageFileName('IMG.HEIC'), isTrue);
    expect(isImageFileName('a.Jpg'), isTrue);
    expect(isImageFileName('doc.pdf'), isFalse);
    expect(isImageFileName('noext'), isFalse);
  });

  testWidgets('intakeFile routes images and files', (tester) async {
    late WidgetRef ref;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (_, r, __) {
        ref = r;
        return const SizedBox();
      }),
    ));

    final photoRoute = intakeFile(ref,
        path: '/tmp/a.heic', name: 'a.heic', size: 10, isImage: true);
    expect(photoRoute, IntakeRoute.optimise);
    expect(container.read(pendingPhotoProvider)?.path, '/tmp/a.heic');
    expect(container.read(archiveProvider), isA<ArchiveInitial>());

    container.read(pendingPhotoProvider.notifier).state = null;
    final fileRoute = intakeFile(ref,
        path: '/tmp/a.pdf', name: 'a.pdf', size: 10, isImage: false);
    expect(fileRoute, IntakeRoute.settings);
    expect(container.read(pendingPhotoProvider), isNull);
    expect(container.read(archiveProvider), isA<ArchiveFileSelected>());
  });
}
