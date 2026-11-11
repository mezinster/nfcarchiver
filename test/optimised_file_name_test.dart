import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/photo/domain/optimised_file_name.dart';

void main() {
  final now = DateTime(2026, 11, 11, 9, 5, 3);

  test('replaces the extension with .jpg', () {
    expect(optimisedFileName('IMG_1234.HEIC', now), 'IMG_1234.jpg');
    expect(optimisedFileName('a.b.png', now), 'a.b.jpg');
  });

  test('appends .jpg to a name without an extension', () {
    expect(optimisedFileName('noext', now), 'noext.jpg');
  });

  test('no name falls back to a timestamp', () {
    expect(optimisedFileName(null, now), 'photo-20261111-090503.jpg');
    expect(optimisedFileName('', now), 'photo-20261111-090503.jpg');
  });
}
