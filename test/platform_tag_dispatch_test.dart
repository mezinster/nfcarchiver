import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/mifare_block_io.dart';
import 'package:nfc_archiver/features/nfc/domain/ndef_io.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// Platform dispatch in the two tag-technology lookups.
///
/// nfc_manager v4 made this load-bearing. Each platform's `from()` casts
/// `tag.data` to *its own* platform's payload type:
///
///     final data = tag.data as TagPigeon?;
///
/// That cast THROWS on the other platform's tag — it does not return null. So a
/// lookup that simply calls `MifareClassicAndroid.from(tag)` blows up on iOS,
/// and since `MifareTagCodec.supports()` runs for every tap, it would take out
/// codec selection on the first tag an iPhone sees.
///
/// v3's classes were platform-agnostic and returned null, so nothing upstream
/// ever had to know. These tests pin the guards that keep that true.
void main() {
  NfcTag fakeTag() => const NfcTag(data: <String, dynamic>{});

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('mifareIoFor yields null on iOS rather than casting an iOS tag', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(mifareIoFor(fakeTag()), isNull);
  });

  test('ndefIoFor yields null on an unsupported platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(ndefIoFor(fakeTag()), isNull);
  });

  test('mifareIoFor yields null on an unsupported platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(mifareIoFor(fakeTag()), isNull);
  });
}
