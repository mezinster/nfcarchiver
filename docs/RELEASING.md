# Releasing

Steps to cut an Android release, in order. Most of it is mechanical; the parts
that have actually gone wrong are called out.

## 1. Land everything first

Every feature PR must be **merged to master and verified there** before the
version is tagged. Verify by content, not by a green PR:

```bash
git merge-base --is-ancestor <feature-commit> origin/master && echo landed
```

A PR can read MERGED while its content never reached master — it has happened
in this repo twice (a stacked PR merged into its base branch, and a merge that
used a stale head SHA). See the `stacked-pr-merge-order` note.

## 2. Bump the version

`pubspec.yaml` is the single source of truth:

```yaml
version: 1.1.0+13
```

Gradle reads both numbers via `flutter.versionCode` / `flutter.versionName`, and
the app shows them at runtime through `PackageInfo.fromPlatform()`. Nothing else
needs editing.

Use a **minor** bump for new user-visible capabilities, a **patch** bump for
fixes only.

## 3. Changelogs — all seven locales

`fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt`, for every one
of `en-US`, `ru-RU`, `tr-TR`, `uk`, `ka-GE`, `pl-PL`, `be-BY`. Without a
translated file, Play and F-Droid fall back to English for that language.

**Google Play caps a changelog at 500 characters.** Check before submitting —
every locale exceeded it on the 1.1.0 draft and had to be trimmed:

```bash
for f in fastlane/metadata/android/*/changelogs/<versionCode>.txt; do
  printf "%-8s %4d\n" "$(echo "$f" | cut -d/ -f4)" "$(wc -m < "$f")"
done
```

## 4. Store listings

Update `full_description.txt` in all seven locales if the release adds features.
Play's limit is 4000 characters.

## 5. Tag

```bash
git tag -a v1.1.0 -m "1.1.0" && git push origin v1.1.0
```

## 6. F-Droid metadata

`fdroid/com.nfcarchiver.nfc_archiver.yml` is a **local copy**. The authoritative
file lives in [fdroiddata](https://gitlab.com/fdroid/fdroiddata) and is updated
by merge request. The local copy has drifted before — it currently carries the
1.0.8 and 1.1.0 build entries only, while upstream also has 1.0.9–1.0.12.

For each release, add a `Builds:` entry and update `CurrentVersion` /
`CurrentVersionCode`.

**`commit:` must be the full SHA of the release commit on master — never a tag
reference.** A new entry is committed with `REPLACE_WITH_RELEASE_COMMIT_SHA` as a
deliberate tripwire; substituting it is step one of submitting the MR:

```bash
git rev-parse v1.1.0^{commit}
```

Then, in a fdroiddata checkout:

```bash
rewritemeta com.nfcarchiver.nfc_archiver
```

`rewritemeta` enforces field ordering and line formatting — `sudo:` must follow
`commit:`, and compound shell commands must be on a single line.

### Constraints that must not drift

- **`compileSdk` stays 34.** F-Droid's build server hits a JDK 21
  `jlink`/`JdkImageTransform` bug on SDK 35. Do not raise it because a plugin
  warns; a warning is not a failure. `flutter_plugin_android_lifecycle` requests
  35 and the release APK still builds.
- **The Flutter version is pinned from the release workflow.** `prebuild`
  extracts `FLUTTER_VERSION` from `.github/workflows/release.yml` with `sed`.
  Renaming or restructuring that workflow breaks the F-Droid build.
- **`pub get` runs in `prebuild`, not `build`.** F-Droid scans dependencies
  between the two, and `.pub-cache` is in `scandelete`. Any build step depending
  on it must set `PUB_CACHE=$(pwd)/.pub-cache`.
- **Categories** are `Connectivity` and `System`. F-Droid does not accept
  `Utility`.
- **Every dependency must be free software.** `flutter_reactive_ble` is
  BSD-3-Clause; its native dependencies (`rxandroidble`, `rxkotlin`,
  `rxandroid`, `kotlin-stdlib`, `protobuf-javalite`) are Apache-2.0 or BSD-3.
  **Never add `flutter_blue_plus`** — it relicensed to a custom non-free licence
  and F-Droid would reject the app.
- **`pubspec.lock` is tracked**, so F-Droid resolves the same versions verified
  locally.

## 7. Verify the built APK

```bash
flutter build apk --release
ls -l build/app/outputs/flutter-apk/app-release.apk
```

Record the size. The 1.1.0 APK is ~24.2 MB; adding Bluetooth support cost
+322,841 bytes (+1.4%), measured rather than estimated.

## Known state at 1.1.0

- `docs/CHAMELEON.md` documents the Chameleon feature for users.
- Chameleon support is validated on hardware for **Mifare Classic only**.
  Inspecting an NTAG over a Chameleon, and a foreign card surfacing without
  ending the session, are untested on a device.
