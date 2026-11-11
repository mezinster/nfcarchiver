import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/photo/data/photo_temp.dart';

void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('photo_temp_test'));
  tearDown(() => base.deleteSync(recursive: true));

  File touch(String rel, DateTime modified) {
    final f = File('${base.path}/$rel')..createSync(recursive: true);
    f.setLastModifiedSync(modified);
    return f;
  }

  test('deletes entries older than launch in both temp folders', () async {
    final launch = DateTime.now();
    final old = launch.subtract(const Duration(hours: 1));
    final fresh = launch.add(const Duration(seconds: 5));
    final oldOpt = touch('photo_optimiser/a.jpg', old);
    final oldShare = touch('share_in/b.heic', old);
    final freshShare = touch('share_in/c.heic', fresh);
    final unrelated = touch('other/d.bin', old);

    await clearPhotoTemp(olderThan: launch, base: base);

    expect(oldOpt.existsSync(), isFalse);
    expect(oldShare.existsSync(), isFalse);
    expect(freshShare.existsSync(), isTrue,
        reason: 'a share copied after launch must survive');
    expect(unrelated.existsSync(), isTrue);
  });

  test('nested folders: stale files go, emptied folders go, fresh stay',
      () async {
    final launch = DateTime.now();
    touch('share_in/old/x.jpg', launch.subtract(const Duration(days: 1)));
    final fresh =
        touch('share_in/new/y.jpg', launch.add(const Duration(seconds: 5)));

    await clearPhotoTemp(olderThan: launch, base: base);

    expect(Directory('${base.path}/share_in/old').existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('missing folders are not an error', () async {
    await clearPhotoTemp(olderThan: DateTime.now(), base: base);
  });
}
