# Photo archiving: pick from Photos, shrink to fit, share in — design

Date: 2026-11-11 · Status: draft for approval · Platforms: Flutter app, iOS **and** Android. The web app is out of scope.

## Intent

The maintainer usually wants to archive **one photo** on NFC tags, starting from the photo gallery. Today this is effectively impossible:

1. **No way to reach the photo library.** `FilePickerScreen` calls `FilePicker.pickFiles()` with no file type (`lib/features/archive/presentation/screens/file_picker_screen.dart:259`), so on iOS it opens only the Files app. The photo library is not there unless a photo was saved to Files first.
2. **A real photo doesn't fit.** An iPhone photo is 2–4 MB (HEIC/JPEG), and one NTAG216 or Mifare 1K holds ~720–850 B of payload, so one photo would need thousands of tags. HEIC/JPEG are already compressed, so GZIP doesn't help.
3. **No share-sheet entry.** NFC Archiver doesn't appear when sharing from Photos.

What success looks like: share a photo from Photos (or pick it inside the app), say how many tags you are willing to use, and the app produces the best-looking JPEG that fits, ready to write.

## Goals

- **G1: "Choose photo" inside the app.** On the archive file-picker screen, add a **Choose photo** action next to the existing file pick, opening the system photo picker (`FilePicker.pickFiles(type: FileType.image)`: PHPicker on iOS, the photo picker on Android). It needs **no photo-library permission**, because the OS hands over only the chosen photo. Do not add `NSPhotoLibraryUsageDescription` or Android media permissions; `test/android_manifest_test.dart` already guards that `READ_MEDIA_*` is stripped.
- **G2: Optimise photo screen.** A new screen between choosing a photo and Archive settings (the maintainer chose this over a card inside Archive settings), with:
  - a large **preview** of the shrunk result, labelled with pixel size, JPEG quality and size in KB;
  - a **"Writing to"** tag-type picker. It offers the same list as Archive settings (`selectableTagTypes(...)`, so the reader-aware Mifare gate and the hidden 4K switch apply) and writes to the same `selectedTagTypeProvider`, so Archive settings opens with it already selected;
  - a **Tags to use** stepper (−/+). In **auto** mode the app finds the best image that fits that many tags;
  - a **Manual** section with longest-side presets and a quality slider (1–100). Touching either switches to manual mode, and a **Back to auto** action returns to the best fit. Manual mode shows the resulting KB and tag count live;
  - **Skip (keep original)**, which continues with the untouched file, and **Continue**, which continues with the optimised JPEG.
- **G3: Share into NFC Archiver, iOS.** A **Share Extension** so NFC Archiver appears in the share sheet of Photos, Files and other apps. It accepts **one item, a photo or any file**. If several are shared, the first is used and the app says so (a snackbar). The app opens, and the item enters the same flow as G1/G2: a photo goes to Optimise photo, any other file to Archive settings.
- **G4: Share into NFC Archiver, Android.** The same behaviour via `ACTION_SEND` (and `ACTION_SEND_MULTIPLE`, taking the first) intent filters, for `image/*` and `*/*`.

## Non-goals

- Multiple photos per archive, or albums. One item per share.
- Video.
- Output formats other than JPEG: no WebP/AVIF/HEIC output. JPEG opens everywhere after restore.
- Image editing (crop, rotate beyond honouring EXIF orientation, filters).
- Any change to the NFAR format or to how tags are written.
- Web app changes.

## Anti-goals (a failure even if it "works")

- **A tag count that lies.** If the screen says 30 tags, Archive settings and the write must need **at most 30**, whatever the user then does with encryption. This is why the fit reserves room for encryption (see "The fit").
- **Leaking metadata.** The optimised JPEG must carry **no EXIF/GPS/camera metadata**. Orientation must be baked into the pixels, so the photo isn't sideways once EXIF is gone.
- **Asking for photo-library permission,** or adding media permissions on Android.
- **Logging the photo.** No file names, paths or bytes in the diagnostics log (existing rule in CLAUDE.md); archive IDs are fine.
- **Silently discarding work.** Sharing into the app while an archive is mid-write (`ArchiveWriting`, or `ArchiveReady` with tags already written) must ask before replacing it.
- **Breaking the free-team build path** documented in CLAUDE.md (Debug configuration + `LocalOverrides.xcconfig`) without saying so. See Constraints.
- **Breaking F-Droid.** Every new dependency must be FOSS with no proprietary Android libraries.

## The optimiser

The method is ported from the maintainer's own web tool at **https://nfcarchiver.com/resize/** (a browser canvas app, so the algorithm is ported, not the code):

- **Resize** so the longest side ≤ a preset. Presets, from the tool: **320, 480, 640, 800, 1024, 1280, 1440, 1600, 1920, 2560, 3840, Original**. Never upscale.
- **Encode JPEG** at quality q (1–100). Transparent pixels are composited onto **white** (the tool does the same).
- **Strip metadata** (the tool's default is on; here it is always on).
- **Size solver:** the tool binary-searches JPEG quality, up to **12** encodes, to hit a target byte size. Here the target comes from the tag count.

Engine (builder's call to confirm, recommended): **`flutter_image_compress`**, which uses the platform's native codecs. It decodes HEIC on iOS and is fast enough to encode a dozen times. A pure-Dart `image` package path is the fallback, but it can't decode HEIC and is slow on 12 MP photos. Decode and downscale once per preset, then binary-search quality on the downscaled image if the engine allows; otherwise re-run from the source with `minWidth/minHeight`. Run it off the UI isolate or natively so the UI stays responsive, and show progress while it searches.

### The fit (auto mode)

Given the chosen tag type T and the tag count N:

- **Byte budget** = what N chunks of T can carry, minus overheads, computed with the **same code path Archive settings uses** for its estimate. That means the same capacity → payload-per-chunk logic (`payloadForCapacity` / chunker), so the two screens can't disagree. Overheads to subtract:
  - the filename wrapper (`_prependFilenameMetadata`) for the **output** name;
  - **always** the encryption overhead (`encryptionOverhead`, 44 B), so turning on encryption later can't add a tag. The cost is at most 44 B of unused room when encryption stays off, which is acceptable.
  - GZIP is assumed **off** (see defaults).
- **Search:** for presets from **Original** (capped by the original's longest side) downward, binary-search quality in **[30, 95]** for the largest JPEG ≤ budget. Pick the best result by this rule: **the largest preset that reaches quality ≥ 50; if none does, the largest preset that fits at any quality ≥ 30.** If nothing fits even at 320 px and quality 30, show "Doesn't fit in N tags; needs at least M" and leave Continue on the smallest result, so the user can raise N or go manual. Exact search bounds and tie-breaks are the builder's to tune, but the rule must be deterministic and unit-tested with a fake encoder.
- **Always re-encode in auto and manual modes** (designer's call): metadata stripping and orientation baking need it, and a photo small enough to fit untouched is rare. The untouched original is reachable through Skip.
- **Starting N** when the screen opens: the tag count needed for that photo at **640 px, quality 70** (picked here as a sensible default), never more than the cap below. After that the stepper belongs to the user. Range: 1 … **the tag count the original file needs** (designer's call). Past that, Skip is the better answer.
- **Scope of the guarantee:** "at most N tags" holds for the **selected tag type**. If the physical tag turns out smaller and `rechunkForDetectedCapacity()` re-chunks, more tags are expected, as today for every file. No extra safety margin.

### Defaults and file naming

- **Output name:** the original base name with `.jpg`, for example `IMG_1234.HEIC` → `IMG_1234.jpg`. If the source gave no name, use `photo-<yyyyMMdd-HHmmss>.jpg`. The name is stored on the tags and restored with the file.
- **GZIP off by default** when the archived file is an optimised JPEG, because it only adds bytes. The user can still turn it on in Archive settings, and the estimate there updates honestly.
- **Skip** keeps the original bytes and name, and doesn't change the compression default.
- The optimised file is written to the app's temp/cache directory and handed to `ArchiveNotifier.selectFile(filePath:, fileName:, fileSize:)`, the existing entry point. Temp files are cleaned up when the archive finishes or is cancelled, or on next launch.

### Which files go to the optimiser

- **Choose photo**, and any shared item whose type is `image/*`: yes.
- **Choose file** returning a file with an image extension (`jpg/jpeg/png/heic/heif/webp/gif`): yes. "Skip" is one tap away. GIFs lose animation if optimised, so Skip is the right choice for them; no special-casing is needed beyond that.
- Everything else goes straight to Archive settings, unchanged.

## Share-in plumbing

Recommended plugin (builder to confirm): **`receive_sharing_intent`**. It covers both the iOS Share Extension and the Android intents, and gives one Dart stream/initial-value API. If it turns out not to work with this project's iOS setup (Flutter Swift Package Manager **and** CocoaPods are both in play here: there is a `Package.resolved` and a generated `Podfile`), fall back to a hand-written Share Extension plus a small method channel. Behaviour must be identical either way.

### iOS

- New target **Share Extension**, bundle ID **`$(NFAR_BUNDLE_ID).ShareExtension`**, which is **`com.nfcarchiver.app.ShareExtension`** for the paid team. Derive it from `NFAR_BUNDLE_ID` so a free-team override still gets a matching prefix. Team `C6LYTC662B` comes from the xcconfigs, never from target settings in `project.pbxproj` (existing CLAUDE.md rule).
- **App Group `group.com.nfcarchiver.app`** on both Runner and the extension, used to hand the file over. Add it to `Runner.entitlements` and the extension's entitlements. Runner keeps NFC `TAG` only, so `test/ios_config_test.dart` still holds.
- A URL scheme (or the plugin's mechanism) to open the host app from the extension.
- `IPHONEOS_DEPLOYMENT_TARGET` **15.0** for the extension too; iPhone-only device family.
- `NSExtensionActivationRule`: one image **or** one file (`NSExtensionActivationSupportsImageWithMaxCount = 1` and `NSExtensionActivationSupportsFileWithMaxCount = 1`, or a predicate equivalent).
- **Privacy manifest:** if the extension's binary uses required-reason APIs (for example file timestamps), give it its own `PrivacyInfo.xcprivacy`. Builder to check at the App Store upload validation.
- **Signing:** automatic signing with `-allowProvisioningUpdates` should register the new App ID and App Group. If App Store Connect or the portal needs a manual tick (App Groups capability), the builder states exactly which.
- **Release safety:** the extension's Release configuration must not be loosened, the same as Runner's (`Release.xcconfig` rule). Extend `test/ios_config_test.dart` to guard the extension's bundle-ID derivation, deployment target, App Group presence and activation rule.
- **Free Personal Team:** free teams can't use App Groups (to verify), and an embedded extension may fail to sign on a Personal Team at all. The free-team path in CLAUDE.md must keep working. It **may gain one documented extra step** (designer's call), for example a `LocalOverrides.xcconfig` setting or a build-setting override that stops embedding the extension. Document it in CLAUDE.md's "Signing on a free Apple ID" and "Installing on your own iPhone" sections. Losing share-in on a free team is acceptable; losing the build is not.

### Android

- `AndroidManifest.xml`: on the main activity, `ACTION_SEND` and `ACTION_SEND_MULTIPLE` intent filters for `image/*` and `*/*`, plus whatever `launchMode` the plugin requires (likely `singleTask`), checked against the existing NFC intent handling so tag discovery still works. Extend `test/android_manifest_test.dart` to guard the filters.
- No new permissions.

### In the app

- Handle both the **cold start** (app launched by the share) and the **warm** case (app already running).
- Route a received photo to `/archive/optimise` (new) and any other file to the existing archive-settings flow via `selectFile`.
- **Busy guard:** "in progress" means `ArchiveWriting`, or any archive state in which at least one tag has already been written. If the notifier doesn't track that today, add the minimal state needed. `ArchiveFileSelected`/`ArchiveConfiguring`/`ArchiveReady` with nothing written are replaced silently. If an archive is in progress, ask "Discard the current archive and start a new one?" before replacing it. On No, drop the shared item and delete its copy. During a restore, take the user to archive only after the same kind of confirmation.
- Shared files are copied into app storage before use. The extension or app-group copy is deleted after hand-off.

## Localization

Every new string in `app_en.arb` and all six translations (ru, tr, uk, ka, pl, be), with `flutter gen-l10n`. The iOS extension's own visible strings, if any (the plugin's default extension UI is usually empty or a spinner), and `CFBundleDisplayName`, which should read **NFC Archiver**, use the app's name, which isn't translated.

## Docs

- The user guide (`site-docs/`, 7 languages) gets a short "Archiving a photo" section: pick or share, set tags, Continue. The docs deploy goes out with the release, not before (no privacy change: still no network, no permissions).
- The privacy policy needs no change: no new data leaves the device, and metadata stripping is a plus. Builder to double-check the wording about files read.
- CLAUDE.md: a short bullet each for the optimiser (engine, the fit's encryption reserve, metadata stripping) and the share extension (bundle ID, App Group, free-team note).

## Constraints (from the project)

- Bundle ID `com.nfcarchiver.app` never changes. The extension ID is a child of it.
- `pubspec.yaml` remains the version source. The next iOS upload needs build ≥ 21 (TestFlight is at 1.2.1 (20)).
- New deps: FOSS licences, F-Droid-compatible, and `pubspec.lock` consistent with `--enforce-lockfile` on the pinned Flutter.
- Errors reach the user through `log.report` with localized messages, never raw exceptions.

## Testing

- **Unit:**
  - the fit's budget arithmetic matches the Archive settings estimate for every selectable tag type;
  - the search rule picks deterministically (fake encoder with a size(width, q) function);
  - the encryption reserve holds: optimise for N, turn on encryption, and the estimate is still ≤ N;
  - output naming;
  - routing of image vs non-image;
  - the busy guard.
- **Widget:** Optimise photo screen auto/manual/back-to-auto, Skip, the tag-type sync with Archive settings, and the "doesn't fit" message.
- **Platform config tests:** `ios_config_test.dart` and `android_manifest_test.dart` extensions above.
- **Manual on hardware (the maintainer's iPhone 13 Pro, plus an Android phone):**
  - share a HEIC photo from Photos (cold and warm start);
  - Choose photo;
  - check the preview orientation of a portrait photo;
  - after restoring, the JPEG has no GPS (check in Photos' info panel);
  - write and restore on NTAG216;
  - share a PDF from Files → Archive settings;
  - share three photos → first used plus a notice;
  - share during a write → confirmation.

## Delivery order

One round, as the maintainer asked, but in **separate PRs** so a stall on an Apple-portal step can't block the rest (designer's call):
1. **iOS Share Extension signing spike first:** an empty extension plus the App Group, built and signed for the paid team, and the free-team path checked. It is the biggest schedule risk, and any manual portal step surfaces here.
2. Choose photo and the optimiser (G1, G2).
3. Share-in plumbing on both platforms (G3, G4) on top of the spike.

The TestFlight build with all three comes at the end.

## Left to the builder

The plugin choice if the recommended ones misbehave; the encoder strategy within `flutter_image_compress`; search bounds and stepper caps within the rule above; the screen's visual details within the chosen layout (big preview on top, "Writing to", "Tags to use", Manual, Skip / Continue); temp-file cleanup timing.

## Decisions record

- The maintainer chose: photo optimiser in scope; target expressed as **number of tags**, auto-best quality **with manual override**; its **own screen** (layout B) rather than a card in Archive settings; the share extension **in the same round**; **Android** share-in included.
- The designer's calls (open to change): JPEG-only output; metadata always stripped; the encryption reserve; GZIP off by default for optimised photos; the tag-type sync with Archive settings; starting N from 640 px / q70; the selection rule (largest preset reaching q ≥ 50); one item per share with a first-item notice; image files from "Choose file" also go to the optimiser; always re-encode (no original-as-candidate); stepper capped at the original's tag count; the guarantee covers the selected tag type only; busy-guard states; free-team recipe may gain one step; separate PRs with the extension spike first.
