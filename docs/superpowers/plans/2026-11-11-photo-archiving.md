# Photo Archiving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user pick a photo from the gallery (or share one, or any file, into the app on iOS and Android), shrink it to fit a chosen number of tags, and archive it.

**Architecture:**
- **Pure Dart core.** A sizing helper makes the Optimise screen and Archive settings compute bytes the same way. A fit search runs behind a `JpegEncoderSession` interface, so it's unit-tested with a fake encoder. A Dart JPEG metadata stripper is the testable last line against leaking EXIF/GPS.
- **Platform code behind two hand-written method channels**, no new pub dependencies:
  - `com.nfcarchiver/photo` decodes once, keeps scaled bitmaps, and encodes JPEGs. It uses ImageIO on iOS, and ImageDecoder/BitmapFactory on Android.
  - `com.nfcarchiver/share_in` hands over a shared item. iOS uses a Share Extension and an App Group inbox; Android uses `ACTION_SEND`.
- **One intake service** routes every incoming file: a photo goes to `/archive/optimise`, anything else to `/archive/settings`.

**Tech Stack:** Flutter 3.44.8, Riverpod `StateNotifier`, go_router, Swift (ImageIO, a UIKit Share Extension), Kotlin (`ImageDecoder`, `android.media.ExifInterface`), and the Ruby `xcodeproj` gem (ships with CocoaPods) for a one-time project edit.

**Spec:** `docs/superpowers/specs/2026-11-11-photo-archiving-design.md`

## Plan-level rulings (deviations the spec allowed)

- **Ruling: no `flutter_image_compress`, no `receive_sharing_intent`.** Use hand-written channels instead.
  - *Why:* `flutter_image_compress` re-decodes the 12 MP source on every call. The fit needs 8–15 encodes, which would take 5–10 s. Our channel decodes once per size. `receive_sharing_intent`'s iOS extension must link a pod, but `ios/Podfile` is generated and untracked (CLAUDE.md), so the extension couldn't be reproduced from the repo. Both channels follow the existing `nfc_capabilities` pattern and add no F-Droid risk.
  - *Cost if wrong:* ~300 lines of Swift/Kotlin to maintain. Swapping the engine later only touches `PlatformJpegSession`.
- **Ruling: the fixed filename wrapper is added to `estimateFromSize`.** It takes a new `fileName` argument.
  - *Why:* the estimate ignores the 2 + name bytes that `createArchive` prepends, so today's estimate can be one tag short. The spec requires the two screens to agree and the count to never lie.
  - *Cost if wrong:* none functionally. Estimates grow by ≤ 257 B.
- **Ruling: the iOS extension opens the app best-effort,** through the responder chain `openURL` to `nfcarchiver-share://`. **The app checks the inbox on launch and on every resume.**
  - *Why:* Apple doesn't support opening the host app from a share extension, and this has broken across iOS releases. The inbox check makes the feature still work, one tap on the app icon later, if the open fails.
  - *Cost if wrong:* the user opens the app manually.
- **Ruling: Android keeps `launchMode="singleTop"`.** A share delivered while the app runs arrives in `onNewIntent`, like the existing NFC intents. No `singleTask` change.
- **Ruling: the stepper's upper cap** is the tag count of the **untouched original** (`tagsNeeded(archivedByteCount(originalSize, originalName, encrypt: true))`), with a floor of 1.

## Global Constraints

- Bundle ID `com.nfcarchiver.app` never changes. The extension is `$(NFAR_BUNDLE_ID).ShareExtension`. The App Group is `group.$(NFAR_BUNDLE_ID)` = `group.com.nfcarchiver.app`.
- Team `C6LYTC662B` only in `ios/Flutter/*.xcconfig`, never in target settings of `project.pbxproj`. `Release.xcconfig` is not loosened and gains no `LocalOverrides` include.
- `Runner.entitlements`: NFC formats stay `TAG` only.
- Every iOS target: `IPHONEOS_DEPLOYMENT_TARGET = 15.0`, `TARGETED_DEVICE_FAMILY = 1`.
- No photo-library or media permissions. No `NSPhotoLibraryUsageDescription`; `READ_MEDIA_*` stays stripped.
- Optimised output is always JPEG with **no APP1–APP15/COM segments** (no EXIF, XMP, GPS), orientation baked into pixels, and transparency on white.
- Presets: `320, 480, 640, 800, 1024, 1280, 1440, 1600, 1920, 2560, 3840` plus Original. Never upscale.
- The fit always reserves `EncryptionService.encryptionOverhead` (44 B) and the filename wrapper (2 + UTF-8 name bytes, capped at 255).
- Auto-fit rule: the largest preset reaching quality ≥ 50 (search [50, 95]); otherwise the largest preset fitting at quality ≥ 30 (search [30, 49]); otherwise "doesn't fit", with the smallest result (320 px or Original if smaller, q30).
- Starting tag count: the tags needed at **640 px, quality 70**, clamped to [1, cap].
- Output name: the original base name + `.jpg`. If there's no name: `photo-yyyyMMdd-HHmmss.jpg`.
- GZIP default **off** when continuing with an optimised JPEG. Skip leaves the compression setting untouched.
- Never log file names, paths or bytes. User-visible errors go through `log.report` with a localized message.
- Every new string goes in `app_en.arb` plus `ru, tr, uk, ka, pl, be`, then `flutter gen-l10n`.
- The next iOS build number is ≥ 21. Don't bump `pubspec.yaml` in this plan.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Delivery

Three branches and PRs, in this order (spec "Delivery order"):
- **PR 1** `feat/share-extension-spike`: Task 1.
- **PR 2** `feat/photo-optimiser`: Tasks 2–6.
- **PR 3** `feat/share-in`: Tasks 7–9.

PR 1 may merge on its own. Its extension already writes the inbox, and an un-drained inbox is harmless. No release is cut until PR 3 is merged.

## Review Focus

1. **A portrait HEIC from an iPhone** must come out upright after metadata is stripped. Native code must bake orientation in. Task 3 pins it with a native self-check on a rotated fixture, plus a manual check.
2. **A photo already smaller than 320 px, or than the chosen preset,** must never be upscaled, and "Original" must not appear twice. Pinned in Task 2 (`candidateSides`).
3. **Changing the tag type on the Optimise screen** must re-run the fit, and Archive settings must open with that type. Pinned in Task 4.
4. **A share arriving while a write has tags written** must ask, and on No it must delete the copy. Pinned in Task 8.
5. **Opening an image that can't be decoded** (corrupt file, or HEIC on Android < 9) must show a localized message offering Skip, never a raw `PlatformException`. Pinned in Task 4.

---

### Task 1: iOS Share Extension target (spike, PR 1)

**Files:**
- Create: `tool/add_share_extension.rb` (a one-time `xcodeproj` edit, kept for reproducibility)
- Create: `ios/ShareExtension/ShareViewController.swift`, `ios/ShareExtension/Info.plist`, `ios/ShareExtension/ShareExtension.entitlements`
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (via the script), `ios/Runner/Runner.entitlements`, `ios/Runner/Info.plist`, `ios/Flutter/Debug.xcconfig`, `ios/Flutter/Release.xcconfig`
- Test: `test/ios_config_test.dart`

**Interfaces:**
- Produces the **inbox contract** that Task 7 reads. Inside the App Group container, `ShareInbox/<uuid>/` holds the item's file under its original name, plus `meta.json` = `{"name": String, "uti": String, "isImage": bool, "count": int}`, where `count` is how many items were shared. The extension writes **only the first** item. It replaces any previous inbox content, so only the latest share is kept.
- Produces the URL scheme `nfcarchiver-share` in Runner's `CFBundleURLTypes`.

- [ ] **Step 1: Write the failing config tests** in `test/ios_config_test.dart`, in a new group `'share extension'`:
  - `ShareExtension.entitlements` and `Runner.entitlements` both contain `com.apple.security.application-groups` with `<string>group.$(NFAR_BUNDLE_ID)</string>`.
  - `project.pbxproj` contains `PRODUCT_BUNDLE_IDENTIFIER = "$(NFAR_BUNDLE_ID).ShareExtension";` and no literal `com.nfcarchiver.app.ShareExtension`.
  - No `DEVELOPMENT_TEAM =` appears in `project.pbxproj`.
  - `ios/ShareExtension/Info.plist` has `NSExtensionPointIdentifier` `com.apple.share-services`, `NSExtensionActivationSupportsImageWithMaxCount` = 1 and `NSExtensionActivationSupportsFileWithMaxCount` = 1. The "max count" refers to what activates the extension. Use a `SUBQUERY` predicate string instead if that's needed to accept a multi-photo selection, and assert whichever form is used.
  - `ios/Runner/Info.plist` contains `<string>nfcarchiver-share</string>`.
  - The existing iPhone-only and deployment-target tests already scan all of `project.pbxproj`, so they cover the new target automatically. Confirm that they do.
- [ ] **Step 2: Run** `flutter test test/ios_config_test.dart`. Expected: the new group FAILS.
- [ ] **Step 3: Write `tool/add_share_extension.rb`.** Using `require 'xcodeproj'`, it adds an `app_extension` target named `ShareExtension`:
  - sources `ios/ShareExtension/ShareViewController.swift`;
  - build settings for Debug/Release/Profile: `INFOPLIST_FILE = ShareExtension/Info.plist`, `CODE_SIGN_ENTITLEMENTS = $(NFAR_SHARE_EXT_ENTITLEMENTS)`, `PRODUCT_BUNDLE_IDENTIFIER = "$(NFAR_BUNDLE_ID).ShareExtension"`, `IPHONEOS_DEPLOYMENT_TARGET = 15.0`, `TARGETED_DEVICE_FAMILY = 1`, `SWIFT_VERSION = 5.0`, `SKIP_INSTALL = YES`, and `baseConfigurationReference` set to the matching `ios/Flutter/{Debug,Release}.xcconfig`, so it picks up `NFAR_BUNDLE_ID` and `DEVELOPMENT_TEAM`;
  - an "Embed App Extensions" copy-files phase (`dstSubfolderSpec 13`) in Runner, plus a target dependency.
  
  The script is idempotent: it exits if the target exists. Run it with CocoaPods' Ruby: `ruby tool/add_share_extension.rb`, or `gem install xcodeproj --user-install` first if the gem isn't found.
- [ ] **Step 4: Write `ShareViewController.swift`** (a `UIViewController`, no storyboard, `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`). In `viewDidAppear`:
  - take the first attachment of the first input item; prefer `UTType.image`, else `UTType.item`;
  - `loadFileRepresentation`; copy the file into the inbox per the contract; count all attachments;
  - attempt `openURL(nfcarchiver-share://shared)` by walking the responder chain to `UIApplication`;
  - `completeRequest`.
  
  If writing fails, `cancelRequest(withError:)`. No UI strings beyond the system sheet. Keep a short comment that opening the host app is best-effort and the app also polls the inbox.
- [ ] **Step 5: Wire xcconfigs and entitlements.**
  - `Debug.xcconfig` and `Release.xcconfig` gain `NFAR_SHARE_EXT_ENTITLEMENTS = ShareExtension/ShareExtension.entitlements`, placed **above** the `LocalOverrides` include in Debug. Release has no include.
  - Add the App Group to both entitlements files.
  - Add `CFBundleURLTypes` with scheme `nfcarchiver-share` to Runner's Info.plist.
  - Set the extension `CFBundleDisplayName` to `NFC Archiver`.
- [ ] **Step 6: Run** `flutter test test/ios_config_test.dart`. Expected: PASS.
- [ ] **Step 7: Build and sign for the paid team:** `flutter build ios --config-only --release && cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates FLUTTER_BUILD_MODE=release -derivedDataPath ../build/ios_dd_aot build`.
  - Expected: `** BUILD SUCCEEDED **`, and `Runner.app/PlugIns/ShareExtension.appex` exists.
  - If signing fails on the App Group or App ID, **stop and report the exact Xcode error.** This is the portal step the spec warned about; the maintainer ticks the box.
  - Then run `flutter build ipa --release --build-number=21` up to the archive only (no upload), to prove Release signs.
  - The extension's privacy manifest is only checked by App Store upload validation, which happens later, at the next TestFlight upload. If that upload reports ITMS-91053 for the extension, add `ios/ShareExtension/PrivacyInfo.xcprivacy` with the reported reason codes, in the extension's Resources phase. Say this in the PR 1 body.
- [ ] **Step 8: Free-team path.** With `ios/Flutter/LocalOverrides.xcconfig.free-team` copied to `LocalOverrides.xcconfig` (restore afterwards; never commit either), find the **one** extra override that lets the Debug build sign without the extension. Recommended: `NFAR_SHARE_EXT_ENTITLEMENTS =` plus an `EXCLUDED_SOURCE_FILE_NAMES`/embed toggle variable, for example `NFAR_EMBED_SHARE_EXT`, used as a condition in the embed phase. Document it in CLAUDE.md's "Signing on a free Apple ID" section. Expected: a free-team build succeeds without `ShareExtension.appex`.
- [ ] **Step 9: Install on the iPhone** (`xcrun devicectl device install app --device 565D5393-0D15-51CE-853A-E80080734758 build/ios_dd_aot/Build/Products/Debug-iphoneos/Runner.app`). Check manually: "NFC Archiver" appears in the Photos share sheet, and sharing a photo opens the app or at least completes without error.
- [ ] **Step 10: Commit** the script, `ios/ShareExtension/*`, pbxproj, entitlements, plists, xcconfigs, test and CLAUDE.md with `feat(ios): share extension target with App Group inbox`. Push and open PR 1.

### Task 2: Sizing helper and the fit search (pure Dart)

**Files:**
- Create: `lib/core/services/archive_sizing.dart`, `lib/features/photo/domain/photo_fit.dart`, `lib/features/photo/domain/jpeg_metadata.dart`
- Modify: `lib/features/archive/data/archive_repository.dart` (`estimateFromSize` gains `required String fileName`; update its 3 callers, including `configure` in `archive_provider.dart`)
- Test: `test/archive_sizing_test.dart`, `test/photo_fit_test.dart`, `test/jpeg_metadata_test.dart`

**Interfaces:**
- Produces in `archive_sizing.dart`:
  - `int filenameWrapperBytes(String fileName)`, which is 2 + min(utf8 length, 255);
  - `int archivedByteCount({required int dataSize, required String fileName, required bool encrypt})`;
  - `int tagsNeeded(int archivedBytes, NfcTagType tagType)`;
  - `int photoByteBudget({required int tags, required NfcTagType tagType, required String fileName})`, which is `tags * tagType.maxPayloadSize - filenameWrapperBytes - EncryptionService.encryptionOverhead`, and may be ≤ 0.
- Produces in `photo_fit.dart`:
  - `const List<int> photoPresets`;
  - `abstract interface class JpegEncoderSession { int get width; int get height; Future<Uint8List> encode({required int maxSide, required int quality}); Future<void> close(); }`;
  - `List<int> candidateSides(int longestSide)`, descending, with the original longest side first, then the presets strictly smaller;
  - `class PhotoFitResult { final int maxSide; final int quality; final Uint8List bytes; final bool fits; }`;
  - `Future<PhotoFitResult> fitToBudget(JpegEncoderSession s, int budgetBytes)`;
  - `Future<PhotoFitResult> encodeManual(JpegEncoderSession s, {required int maxSide, required int quality, required int budgetBytes})`.
- Produces in `jpeg_metadata.dart`: `Uint8List stripJpegMetadata(Uint8List jpeg)`, which removes APP1–APP15 and COM segments and keeps APP0/JFIF, DQT, SOF, DHT, SOS and the data. It throws `FormatException` for non-JPEG input.

- [ ] **Step 1: Write the failing tests.**
  - `archive_sizing_test.dart`: for each `NfcTagType` with `maxPayloadSize > 0` and data sizes `{0, 1, payload-1, payload, 5*payload+3}` × names `{'a.jpg', 'IMG_1234.jpg', 300×'x' + '.jpg'}` × encrypt `{false, true}`, `tagsNeeded(archivedByteCount(...))` equals the chunk count that `ArchiveRepository.createArchiveFromBytes` really produces (use the repository with a fixed password). Also, `estimateFromSize(..., fileName:)` returns the same count when `compress: false`.
  - `photo_fit_test.dart` uses a `FakeJpegSession(width, height, size: (side, q) => ...)` that records its calls. Tests:
    - `candidateSides(4032)` = `[4032, 3840, 2560, …, 320]`; `candidateSides(640)` = `[640, 480, 320]`; `candidateSides(200)` = `[200]`.
    - With size = side² × q / 1000 and a budget allowing 1024 at q50 but not 1280 at q50, the result is `maxSide 1024`, the largest q ≤ 95 that fits, and `fits: true`.
    - When no side reaches q50 but 480 fits at q35, the result is `maxSide 480` with q in [30, 49] maximal.
    - When nothing fits, `fits: false`, `maxSide 320`, `quality 30`.
    - Budget ≤ 0 gives `fits: false` with no more than one encode.
    - Determinism: the same inputs give the same calls and result.
    - Encode count ≤ `candidateSides.length + 7`.
  - `jpeg_metadata_test.dart`: a hand-built minimal JPEG (SOI, APP0, APP1 "Exif\0\0…GPS", COM, DQT, SOF0, DHT, SOS, data, EOI) loses its APP1 and COM, keeps everything else byte-identical, and the result contains no `Exif` bytes. A JPEG without metadata is returned unchanged. PNG bytes throw `FormatException`.
- [ ] **Step 2: Run** `flutter test test/archive_sizing_test.dart test/photo_fit_test.dart test/jpeg_metadata_test.dart`. Expected: FAIL (undefined).
- [ ] **Step 3: Implement.** `fitToBudget` follows the Global Constraints rule:
  - walk `candidateSides`, encoding at q50, until one fits;
  - binary-search [50, 95] at that side;
  - if none fit at q50, walk again at q30 and binary-search [30, 49];
  - otherwise return the last side at q30 with `fits: false`.
  
  `encodeManual` encodes once, and `fits` = `bytes.length <= budget`. Make `estimateFromSize` add `filenameWrapperBytes(fileName)` before compression.
- [ ] **Step 4: Run** the three test files plus `flutter test` (everything). Expected: PASS, with existing estimate tests updated only where the count legitimately grew.
- [ ] **Step 5: Commit** `feat(photo): sizing helper, fit search, JPEG metadata stripper`.

### Task 3: Native JPEG encoder channel

**Files:**
- Create: `lib/features/photo/data/platform_jpeg_session.dart`, `ios/Runner/PhotoEncoder.swift`, `android/app/src/main/kotlin/com/nfcarchiver/nfc_archiver/PhotoEncoder.kt`
- Modify: `ios/Runner/AppDelegate.swift` (register the channel through `engineBridge.pluginRegistry.registrar(forPlugin: "PhotoEncoder")`), `android/.../MainActivity.kt`, `ios/Runner.xcodeproj/project.pbxproj` (add `PhotoEncoder.swift` to Runner's sources)
- Test: `test/platform_jpeg_session_test.dart`

**Interfaces:**
- Consumes: `JpegEncoderSession` and `stripJpegMetadata` (Task 2).
- Produces:
  - `const photoChannel = MethodChannel('com.nfcarchiver/photo')`;
  - `static Future<PlatformJpegSession> PlatformJpegSession.open(String path)`, which throws `PhotoDecodeException` (a new `class PhotoDecodeException implements Exception`) when the native side returns `PlatformException(code: 'decode_failed')`;
  - the channel methods `open {path} → {id: int, width: int, height: int}` (dimensions **after** orientation), `encode {id, maxSide, quality} → Uint8List`, and `close {id}`.
  
  Dart's `encode` passes every result through `stripJpegMetadata`.
- Native behaviour:
  - **iOS:** `CGImageSourceCreateWithURL`, then for each maxSide `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform: true` and `kCGImageSourceThumbnailMaxPixelSize: maxSide` (cached per maxSide). Draw onto white in a `CGContext`, then `CGImageDestination` JPEG with `kCGImageDestinationLossyCompressionQuality = q/100` and **no** properties dictionary.
  - **Android:** API ≥ 28 uses `ImageDecoder` with `setTargetSize` (it applies EXIF orientation). Below that, use `BitmapFactory` with `inSampleSize` and scaling, then rotate per `android.media.ExifInterface(InputStream)`. Draw onto a white `Canvas`, then `Bitmap.compress(JPEG, q, …)`.
  - Never upscale on either platform: if maxSide ≥ the original longest side, use the original size.
  - Run work off the main thread: a background `DispatchQueue` on iOS, an executor on Android, with results posted on main.
  - Sessions live in a map by id, and `close` frees them.

- [ ] **Step 1: Write the failing Dart test** (`platform_jpeg_session_test.dart`) with a mock channel handler:
  - `open` returns `{id: 7, width: 3024, height: 4032}` and the session reports those values;
  - `encode` returns a JPEG containing an APP1 Exif segment, and the session returns it **without** APP1;
  - `decode_failed` maps to `PhotoDecodeException`;
  - `close` sends `{id: 7}`.
- [ ] **Step 2: Run** `flutter test test/platform_jpeg_session_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the Dart class and both native encoders.
- [ ] **Step 4: Run** `flutter test test/platform_jpeg_session_test.dart` and `flutter analyze`. Expected: PASS, clean.
- [ ] **Step 5: Native check on device** (Review Focus 1). Build the AOT iOS app (Task 1 Step 7 command) and install it. A temporary debug-only button is **not** to be committed; instead, verify through Task 4's screen once it exists. Note in the task report that the orientation and GPS check is carried out in Task 4 Step 6. Build Android with `flutter build apk --debug` to prove the Kotlin compiles.
- [ ] **Step 6: Commit** `feat(photo): native JPEG encoder channel (ImageIO / ImageDecoder)`.

### Task 4: Optimise photo screen

**Files:**
- Create: `lib/features/photo/presentation/photo_optimiser_provider.dart`, `lib/features/photo/presentation/photo_optimiser_screen.dart`, `lib/features/photo/domain/optimised_file_name.dart`
- Modify: `lib/app.dart` (route `optimise` under `/archive`, `name: '/archive/optimise'`), `lib/l10n/app_*.arb` (7 files)
- Test: `test/photo_optimiser_test.dart`, `test/optimised_file_name_test.dart`

**Interfaces:**
- Consumes: Tasks 2 and 3; `selectedTagTypeProvider` and `compressionEnabledProvider` (`archive_provider.dart`); `selectableTagTypes(...)`, `mifareClassicAvailableProvider` and `mifare4kEnabledProvider` (same as `archive_settings_screen.dart`); `ArchiveNotifier.selectFile(filePath:, fileName:, fileSize:)`.
- Produces:
  - `final pendingPhotoProvider = StateProvider<PendingPhoto?>((_) => null)`, with `class PendingPhoto { final String path; final String? name; final int size; }`. Task 5 and Task 8 set it, then `context.go('/archive/optimise')`;
  - `final jpegSessionOpenerProvider = Provider<Future<JpegEncoderSession> Function(String path)>((_) => PlatformJpegSession.open)`, overridable in tests;
  - `photoOptimiserProvider`, a `StateNotifierProvider.autoDispose`. Its state holds `tagType`, `tags`, `cap`, `mode` (`auto|manual`), `manualSide`, `manualQuality`, `result` (a `PhotoFitResult?`), `busy`, and `error` (an enum: `none|decodeFailed`). Methods: `setTags(int)`, `setTagType(NfcTagType)`, `setManual({int? side, int? quality})`, `backToAuto()`, and `Future<void> continueWithResult()`. The last one writes `result.bytes` to `getTemporaryDirectory()/photo_optimiser/<name>`, calls `selectFile`, sets `compressionEnabledProvider = false` and `selectedTagTypeProvider = tagType`. `skip()` calls `selectFile` with the original and sets only `selectedTagTypeProvider`;
  - `String optimisedFileName(String? original, DateTime now)`.
- Screen layout (spec, layout B), top to bottom:
  - the preview (`Image.memory(result.bytes)`) with the label `{w}×{h} · q{q} · {KB}`;
  - "Writing to" `ChoiceChip`s;
  - the "Tags to use" stepper (−/+, clamped [1, cap]) with the best-fit line or the "doesn't fit, needs at least {m}" line, where m = the smallest tag count whose budget fits the q30 smallest result;
  - "Manual": `ChoiceChip`s for `candidateSides` with Original labelled, a quality `Slider` 1–100, and "Back to auto" while in manual mode;
  - `TextButton` Skip and `FilledButton` Continue (disabled while busy).
  
  When re-fitting, debounce stepper and slider changes by 250 ms and drop stale results.
- New l10n keys, with English text:

  | Key | English |
  |---|---|
  | `optimisePhotoTitle` | "Optimise photo" |
  | `writingTo` | "Writing to" |
  | `tagsToUse` | "Tags to use" |
  | `photoBestFit` | "Best fit: {side} px, quality {quality}" |
  | `photoDoesNotFit` | "Doesn't fit in {tags} tags — needs at least {needed}" |
  | `photoManual` | "Manual" |
  | `photoOriginalSize` | "Original" |
  | `photoQuality` | "Quality {quality}" |
  | `photoBackToAuto` | "Back to auto" |
  | `photoSkip` | "Skip (keep original)" |
  | `photoContinue` | "Continue" |
  | `photoCannotRead` | "This photo can't be read here. Use Skip to archive the original file." |

- [ ] **Step 1: Write the failing tests.**
  - `optimised_file_name_test.dart`: `IMG_1234.HEIC` → `IMG_1234.jpg`; `a.b.png` → `a.b.jpg`; `noext` → `noext.jpg`; `null` or `''` at 2026-11-11 09:05:03 → `photo-20261111-090503.jpg`.
  - `photo_optimiser_test.dart`, a widget test with `FakeJpegSession` (from Task 2's test support; move it to `test/support/fake_jpeg_session.dart`) overriding `jpegSessionOpenerProvider`:
    - it opens with tags = the starting count (640/q70 rule) and auto mode;
    - "+" re-fits with a larger budget, and the label updates;
    - picking another tag type re-fits, and Continue sets `selectedTagTypeProvider` to it;
    - moving the slider switches to manual, and "Back to auto" restores the auto result;
    - Continue calls `selectFile` with the `.jpg` name and the result's byte length, and turns `compressionEnabledProvider` off;
    - Skip calls `selectFile` with the original path, name and size, and leaves compression alone;
    - an opener throwing `PhotoDecodeException` shows `photoCannotRead`, leaves Skip enabled and Continue disabled, and the test asserts no `PlatformException` text is shown;
    - a budget that can't fit shows `photoDoesNotFit` with the right numbers;
    - "+" at the cap (the original's tag count) stays at the cap, and "−" at 1 stays at 1;
    - the encryption reserve: after Continue, `ArchiveRepository.estimateFromSize(dataSize: result.length, fileName: name, encrypt: true, compress: false).chunksNeeded <= tags`.
- [ ] **Step 2: Run** `flutter test test/optimised_file_name_test.dart test/photo_optimiser_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the provider, screen, route and ARB strings in all 7 languages, then run `flutter gen-l10n`. Also add `Future<void> clearPhotoTemp()` in `optimised_file_name.dart`'s sibling `lib/features/photo/data/photo_temp.dart`, which deletes `getTemporaryDirectory()/photo_optimiser/` and `getTemporaryDirectory()/share_in/`. Call it unawaited from `main()` after `startDiagnostics`, so files from a finished or cancelled archive are gone by the next launch (spec "Defaults and file naming").
- [ ] **Step 4: Run** the two test files, `flutter analyze` and `flutter test`. Expected: PASS, clean.
- [ ] **Step 5: Commit** `feat(photo): Optimise photo screen`.
- [ ] **Step 6 (manual, after Task 5 lands, on the iPhone and an Android phone):**
  - a portrait HEIC shows upright in the preview;
  - archive and restore on NTAG216 with exactly the shown tag count;
  - the restored JPEG has no location in Photos' info panel;
  - record the results in the PR body.

### Task 5: Choose photo, and the intake router

**Files:**
- Create: `lib/features/archive/domain/archive_intake.dart`
- Modify: `lib/features/archive/presentation/screens/file_picker_screen.dart` (`_pickFile` → `_pick({required bool photo})`, a second button), `lib/l10n/app_*.arb`
- Test: `test/archive_intake_test.dart`

**Interfaces:**
- Consumes: `pendingPhotoProvider` (Task 4), `ArchiveNotifier.selectFile`.
- Produces:
  - `bool isImageFileName(String name)`, true for the extensions `jpg, jpeg, png, heic, heif, webp, gif` (case-insensitive);
  - `enum IntakeRoute { optimise, settings }`;
  - `IntakeRoute intakeFile(WidgetRef ref, {required String path, required String? name, required int size, required bool isImage})`. It sets `pendingPhotoProvider` for images and calls `selectFile` otherwise. The caller does `context.go(route == IntakeRoute.optimise ? '/archive/optimise' : '/archive/settings')`.
  
  Today `_pickFile` only selects the file, so check how the screen reaches settings and keep that behaviour for non-images.
- New l10n keys: `choosePhoto` = "Choose photo", `chooseFile` = "Choose file" (if the existing button label already says that, reuse its key instead).

- [ ] **Step 1: Write the failing tests:**
  - `isImageFileName` for `IMG.HEIC` (true), `a.Jpg` (true), `doc.pdf` (false), `noext` (false);
  - `intakeFile` with `isImage: true` sets `pendingPhotoProvider` and doesn't touch `archiveProvider`;
  - with `isImage: false` it leaves `pendingPhotoProvider` null and puts `archiveProvider` in `ArchiveFileSelected`.
- [ ] **Step 2: Run** `flutter test test/archive_intake_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** "Choose photo" calls `FilePicker.pickFiles(type: FileType.image)` and always counts as an image. "Choose file" uses `isImage: isImageFileName(file.name)`.
- [ ] **Step 4: Run** `flutter test` and `flutter analyze`. Expected: PASS, clean. `test/android_manifest_test.dart` must still pass, since no media permissions were added.
- [ ] **Step 5: Commit** `feat(archive): Choose photo and image routing to the optimiser`.

### Task 6: PR 2 wrap-up

- [ ] **Step 1:** Add a CLAUDE.md bullet under Features:
  - Photo optimiser: the native `com.nfcarchiver/photo` channel, why it isn't `flutter_image_compress`, the 44 B encryption reserve, metadata stripped natively **and** by `stripJpegMetadata`, the auto-fit rule;
  - the `estimateFromSize(fileName:)` change.
- [ ] **Step 2:** Run `flutter analyze && flutter test`. Expected: clean, all pass.
- [ ] **Step 3:** Commit `docs: photo optimiser notes`. Push and open PR 2, with the Task 4 Step 6 manual results in the body.

### Task 7: Native share inbox (iOS reader, Android intents)

**Files:**
- Create: `ios/Runner/ShareInbox.swift`, `android/.../ShareInbox.kt`
- Modify: `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj` (add `ShareInbox.swift`), `android/.../MainActivity.kt`, `android/app/src/main/AndroidManifest.xml`
- Test: `test/android_manifest_test.dart`

**Interfaces:**
- Consumes: the inbox contract (Task 1).
- Produces the channel `com.nfcarchiver/share_in`:
  - **Dart → native** `take` → `null` or `{path: String, name: String?, isImage: bool, count: int}`. The `path` is a copy inside the app's own temp dir, and the native side has already deleted its inbox or cache copy.
  - **Native → Dart** `onShareAvailable` (no args), invoked when a share arrives while the app runs: Android `onNewIntent`, and iOS URL open via the scene. If the iOS scene hook is awkward under `FlutterSceneDelegate`, skip it; the Dart side's resume check covers it.
- Android:
  - intent filters on `.MainActivity` for `ACTION_SEND` and `ACTION_SEND_MULTIPLE` with `category DEFAULT`, `mimeType="image/*"` and `mimeType="*/*"`. Keep `launchMode="singleTop"` and the NFC filters untouched;
  - `ShareInbox.kt` copies the first `EXTRA_STREAM` URI (for `SEND_MULTIPLE`, the first of the list) through `contentResolver` into `cacheDir/share_in/`. It gets the name from `OpenableColumns.DISPLAY_NAME` and sets `isImage` from `contentResolver.getType(uri)?.startsWith("image/")`;
  - plain `EXTRA_TEXT` shares are ignored;
  - only `SEND`/`SEND_MULTIPLE` intents are handled; everything else passes to `super`.

- [ ] **Step 1: Write the failing manifest tests:**
  - `.MainActivity` declares `android.intent.action.SEND` and `SEND_MULTIPLE` with `image/*` and `*/*`;
  - `launchMode` is still `singleTop`;
  - the NDEF_DISCOVERED filter is still present;
  - still no `READ_MEDIA_*`/`READ_EXTERNAL_STORAGE`.
- [ ] **Step 2: Run** `flutter test test/android_manifest_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** both native sides and the manifest.
- [ ] **Step 4: Run** `flutter test test/android_manifest_test.dart`, `flutter build apk --debug`, and the iOS build (Task 1 Step 7 command). Expected: PASS, and both build.
- [ ] **Step 5: Commit** `feat(share): native share-in inbox for iOS and Android`.

### Task 8: Dart share-in, the busy guard, routing

**Files:**
- Create: `lib/features/share_in/share_inbox.dart`, `lib/features/share_in/share_in_listener.dart`
- Modify: `lib/app.dart` (wrap the router child in `ShareInListener`), `lib/l10n/app_*.arb`
- Test: `test/share_in_test.dart`

**Interfaces:**
- Consumes: the `com.nfcarchiver/share_in` channel (Task 7), `intakeFile` (Task 5), `archiveProvider`, `restoreProvider`, `ArchiveNotifier.reset()`, `RestoreNotifier.reset()`.
- Produces:
  - `class SharedItem { final String path; final String? name; final bool isImage; final int count; }`;
  - `class ShareInbox { Future<SharedItem?> take(); }` (the channel wrapper; `shareInboxProvider` is overridable);
  - `bool archiveWorkInProgress(ArchiveState s)`, true for `ArchiveReady` or `ArchiveWriting` with `writtenChunks.isNotEmpty`;
  - `bool restoreWorkInProgress(RestoreState s)`, true for `RestoreScanning` with `sessions.isNotEmpty`, `RestoreReady`, or `RestoreInProgress`;
  - `ShareInListener`, a `ConsumerStatefulWidget` and `WidgetsBindingObserver`. It calls `take()` after the first frame, on `AppLifecycleState.resumed`, and on `onShareAvailable`, with one call in flight at a time. Given an item:
    - if work is in progress, show a dialog `shareDiscardTitle`/`shareDiscardBody` with `shareDiscardConfirm`/`cancel`. On cancel, delete the item's file and stop. On confirm, `reset()` the busy notifier(s);
    - then `intakeFile(...)` and navigate (using the router, not a context below it);
    - if `count > 1`, show a snackbar `shareOnlyFirst`.
- New l10n keys:

  | Key | English |
  |---|---|
  | `shareDiscardTitle` | "Start a new archive?" |
  | `shareDiscardBody` | "Some tags of the current archive are already written. Starting a new archive discards it." |
  | `shareDiscardConfirm` | "Discard and continue" |
  | `shareOnlyFirst` | "Only the first of {count} items was taken — NFC Archiver archives one file at a time." |

- [ ] **Step 1: Write the failing tests** (`share_in_test.dart`) with a fake `ShareInbox`:
  - the busy-guard functions return the right values for each state listed above, including `ArchiveReady` with an empty `writtenChunks` (false);
  - a cold-start item that is an image lands on `/archive/optimise` with `pendingPhotoProvider` set;
  - a non-image item lands on `/archive/settings`;
  - `count: 3` shows `shareOnlyFirst` with 3;
  - with `ArchiveWriting(writtenChunks: {0})`, a dialog appears. Cancel deletes the temp file and the archive state is unchanged; confirm resets and routes;
  - a resume event triggers `take()`; two rapid resumes cause only one `take()` call while the first is pending.
- [ ] **Step 2: Run** `flutter test test/share_in_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement**, add the ARB strings in all 7 languages, then run `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter analyze && flutter test`. Expected: clean, all pass.
- [ ] **Step 5: Commit** `feat(share): route shared items into the archive flow`.

### Task 9: Docs, on-device checks, PR 3

**Files:**
- Modify: `site-docs/docs/{en,ru,tr,uk,ka,pl,be}/archive.md` (a section "Archiving a photo"), `CLAUDE.md`

- [ ] **Step 1:** Write the user-guide section in English: Choose photo, or share from Photos/Gallery → Optimise photo → set "Tags to use" (best quality is found automatically; Manual to override; Skip keeps the original) → Continue. Add one line: location and camera data are removed from the optimised photo. Then translate it into the 6 other languages, keeping the headings parallel. Do **not** mention 4K. Re-read `privacy.md` (en) for anything this feature makes untrue, such as a claim that the app reads only files the user picks. Shared files are still user-chosen, so the expected result is no change; record the check in the PR body.
- [ ] **Step 2:** Run the site check. Find its exact invocation in `site-docs/README.md`: it builds the site and runs `check_site.py` on the sources and the built trees. Expected: passes.
- [ ] **Step 3:** Add a CLAUDE.md bullet: the share-in channel and inbox contract, the App Group `group.com.nfcarchiver.app`, the extension bundle ID, best-effort open plus the resume check, Android `singleTop` with `onNewIntent`, and the free-team override from Task 1.
- [ ] **Step 4: Manual on the iPhone** (AOT install) **and an Android phone:**
  - share a HEIC from Photos with the app killed (cold start) and with it in the background (warm start);
  - share a PDF from Files, which goes to Archive settings;
  - share 3 photos: the first is taken, with the notice;
  - share during a write with 1+ tags written: the dialog appears, and both buttons behave.
  
  Record the results in the PR body.
- [ ] **Step 5:** Run `flutter analyze && flutter test`. Commit `docs: photo archiving and share-in`. Push and open PR 3. No `pubspec.yaml` bump; the next TestFlight build uses `--build-number=21` or higher.
