import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../photo/presentation/photo_optimiser_provider.dart';
import '../presentation/providers/archive_provider.dart';

const _imageExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif'};

/// True when [name] carries an image extension (case-insensitive).
bool isImageFileName(String name) {
  final ext = p.extension(name).toLowerCase();
  return ext.length > 1 && _imageExtensions.contains(ext.substring(1));
}

/// Where a freshly taken-in file goes next.
enum IntakeRoute { optimise, settings }

/// Hands a picked or shared file to the right place: images wait for the
/// optimiser in [pendingPhotoProvider]; everything else is selected for
/// archiving as before. The caller navigates.
IntakeRoute intakeFile(
  WidgetRef ref, {
  required String path,
  required String? name,
  required int size,
  required bool isImage,
}) {
  if (isImage) {
    ref.read(pendingPhotoProvider.notifier).state =
        PendingPhoto(path: path, name: name, size: size);
    return IntakeRoute.optimise;
  }
  ref.read(archiveProvider.notifier).selectFile(
        filePath: path,
        fileName: name ?? p.basename(path),
        fileSize: size,
      );
  return IntakeRoute.settings;
}
