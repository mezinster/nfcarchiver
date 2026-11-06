# iOS App Store Release — Handoff Plan

> **For the Claude session picking this up:** read this file top to bottom, then `CLAUDE.md` → *Apple App Store Publishing* and *iOS Development (Mac)*. Work the phases in order; each step has a **Done when** you must verify, not assume. Tick boxes in this file and commit as you go, so the next session knows where you stopped.

**Goal:** ship NFC Archiver (Flutter) to the App Store, iPhone only, signed by the paid team.

**Created:** 2026-11-06, on Linux/WSL (no Mac available). Phases 0–1 happen in a browser; Phase 3 onward needs the Mac with Xcode 26.3.

---

## Context you will not find in the code

- **Account:** the paid Apple Developer Program membership belongs to **the maintainer's friend** (Account Holder). The maintainer is a **team member** there. Only the Account Holder can accept agreements. The store's seller name is the Account Holder's. A later move to the maintainer's own account goes through Apple's App Transfer, and the bundle ID must not change.
- **Until now iOS ran only on a free Personal Team.** That meant no Core NFC entitlement, and only the Chameleon (Bluetooth) path was ever exercised on a device. **The `nfc_manager` iOS layer (`IosNdefIO`, `NdefStatusIos`, the `defaultTargetPlatform` guards in `ndefIoFor`/`mifareIoFor`) has never run.** Phase 3 is its first real test. Expect bugs there.
- **iPhone only** was decided on purpose: iPads have no NFC radio, and iPad support would require iPad screenshots.
- **Signing approach:** Xcode automatic signing. No hand-made CSR, `.p12` or profile.

## Decisions still open (ask the maintainer, don't guess)

| # | Question | Blocks | Notes |
|---|---|---|---|
| D1 | **Team ID** (10 chars, developer.apple.com → Membership) | Phase 2b, Phase 3 | **Decided 2026-11-06: `C6LYTC662B`.** |
| D2 | **Can the team register `com.nfcarchiver.nfcArchiver`?** | Everything after Phase 1 | **2026-11-06: maintainer will try to register it in Phase 1.1; fall back only if refused.** `Debug.xcconfig` records that a free team once got *"cannot be registered … not available"*, so another team owns it. If the friend's team can't register it either, choose a new ID (e.g. `com.nfcarchiver.app`) **before the first upload**, and change `NFAR_BUNDLE_ID` in `ios/Flutter/Debug.xcconfig`, `Profile.xcconfig` and `Release.xcconfig`, plus the `RunnerTests` IDs in `project.pbxproj`. |
| D3 | **`ITSAppUsesNonExemptEncryption`** | Phase 4 (any upload asks) | The app ships its own AES-256-GCM through `pointycastle`, so the honest answer is probably **YES, standard algorithms, mass-market exemption**, not `NO`. **Decided 2026-11-06 by the maintainer: YES, standard algorithms, mass-market exemption.** Key added in 2c. |

---

## Phase 0 — Account (browser, maintainer + friend)

- [ ] **0.1** The friend adds the maintainer in App Store Connect → Users and Access as **Admin**, or **App Manager** with *Access to Certificates, Identifiers & Profiles*.
  **Done when:** the maintainer can open developer.apple.com → Certificates, Identifiers & Profiles for the friend's team.
- [x] **0.2** Record the Team ID → D1.
- [ ] **0.3** Check whether the Free Apps agreement is active (App Store Connect → Business). Only the Account Holder can accept it.

## Phase 1 — Developer portal (browser)

- [ ] **1.1** Identifiers → **+** → App IDs → App → *Explicit* bundle ID (answer to D2). Enable **NFC Tag Reading**. No other capability is needed: Bluetooth needs only the Info.plist string, which already exists.
  **Done when:** the identifier is listed with NFC Tag Reading ticked.
- [ ] **1.2** Nothing else here. Certificates, devices and profiles are created by Xcode in Phase 3.

## Phase 2 — Repo prep (no Mac needed)

### 2a — DONE in PR #119 (`chore/ios-paid-team-prep`)

- [x] `Runner.entitlements` requests **`TAG` only**. App Store upload rejects `NDEF` (ITMS-90778 "NDEF is disallowed"); `nfc_manager` 4.2.1 only opens `NFCTagReaderSession` (checked in `NfcManagerPlugin.swift`).
- [x] `TARGETED_DEVICE_FAMILY = 1` in all project configs; `UISupportedInterfaceOrientations~ipad` removed.
- [x] `ios/Runner/PrivacyInfo.xcprivacy` added (no tracking, no collected data, FileTimestamp `C617.1`) and wired into the Runner **Resources** build phase (IDs `B7E4A1C1…C0FFEE` / `B7E4A1C2…C0FFEE`).
- [x] `test/ios_config_test.dart` guards all of the above.
- [ ] **Merge PR #119** (check CI is green first).

### 2b — needs D1

- [x] **2b.1** Add `DEVELOPMENT_TEAM = <TEAMID>` to **`ios/Flutter/Release.xcconfig`**, and to **`ios/Flutter/Debug.xcconfig` above the `#include? "LocalOverrides.xcconfig"` line**, so a free-team developer can still override it. Profile has its own xcconfig (commit `13d472a`); check it and set it there too if it signs separately.
  **Never put `DEVELOPMENT_TEAM` in the target settings of `project.pbxproj`:** target settings beat xcconfig values and would silently override `LocalOverrides.xcconfig`.
- [x] **2b.2** Add a guard to `test/ios_config_test.dart`: `project.pbxproj` contains no `DEVELOPMENT_TEAM =` line.
- [ ] **2b.3** If D2 forced a new bundle ID, change it in the same PR.

### 2c — needs D3

- [x] **2c.1** Add the `ITSAppUsesNonExemptEncryption` key (and `ITSEncryptionExportComplianceCode` if Apple issues one) with a guard test.

## Phase 3 — Mac: first signed device build

Prerequisites: Xcode 26.3 (Sequoia: `.xip` from developer.apple.com/download/all), Developer Mode on the iPhone, Flutter checked out at the CI tag (`~/flutter` is a git clone; see `.github/workflows/ci.yml`; **never `flutter upgrade`**).

- [ ] **3.1** `git pull` on master, then `flutter pub get --enforce-lockfile`. **Do not run `pod install` by hand.**
- [ ] **3.2** **Delete `ios/Flutter/LocalOverrides.xcconfig`** if it exists. It blanks the NFC entitlement and swaps the bundle ID in Debug.
- [ ] **3.3** Xcode → Settings → Accounts: sign in with the maintainer's Apple ID; the friend's team should be listed.
- [ ] **3.4** Open `ios/Runner.xcworkspace` → Runner target → Signing & Capabilities: *Automatically manage signing* ON, team = friend's team. NFC Tag Reading should already show (it comes from the entitlements file).
  **If Xcode writes `DEVELOPMENT_TEAM` into `project.pbxproj`, discard that hunk** (see 2b.1).
- [ ] **3.5** `flutter run --release` on the iPhone (AOT, so it survives detach). With a paid team, plain Release should now sign. The *"Personal development teams … do not support NFC"* failure in CLAUDE.md was a free-team problem.
  **Done when:** the app launches from the Home Screen with no cable attached.
- [ ] **3.6** **Core NFC hardware smoke test**, the first ever (record the results in the PR or a memory note):
  - [ ] Archive a small file onto NTAG215/216 with the phone's radio.
  - [ ] Restore it in a different scan order; the restored file opens or shares correctly.
  - [ ] Without a Chameleon, the tag-type list does **not** offer Mifare Classic (`supportsMifareClassic()` is false on the phone).
  - [ ] With a Chameleon connected, Mifare Classic appears and a write + restore works. This re-checks the Bluetooth path with the entitlement present.
  - [ ] Cancel the iOS NFC sheet mid-write: the app recovers and shows no stuck state.
- [ ] **3.7** Fix whatever 3.6 breaks with TDD, in separate PRs. Don't stack fixes onto the release branch.
- [ ] **3.8** Update CLAUDE.md: the free-team sections (*Signing on a free Apple ID*, *Installing on your own iPhone*) become a fallback; the paid-team flow becomes the primary path.

## Phase 4 — App Store Connect + TestFlight

- [ ] **4.1** App Store Connect → Apps → **+**: name *NFC Archiver*, primary language English (U.S.), bundle ID from D2, SKU `nfcarchiver-ios`. Category: Utilities (secondary: Productivity).
- [ ] **4.2** Build and upload: `flutter build ipa --release`, then upload `build/ios/ipa/*.ipa` with the **Transporter** app or `xcrun altool --upload-app`. Alternatively use Xcode Organizer → Distribute App → App Store Connect.
  **Done when:** the build shows as *Ready to Test* in TestFlight with no ITMS errors in the email.
- [ ] **4.3** If validation complains, the likely causes are:
  - `com.apple.developer.nfc.readersession.felica.systemcodes` is an **empty array** in `Info.plist`. It came from the `nfc_manager` setup docs, and it's not known whether upload accepts it. If it's flagged, remove the key; the app doesn't use FeliCa.
  - Missing privacy-manifest reasons (ITMS-91053): add the API category and reason it names to `PrivacyInfo.xcprivacy`.
- [ ] **4.4** Add the maintainer and the friend as **internal testers**. Internal testing needs no review. Builds last 90 days.

## Phase 5 — Listing + review

- [ ] **5.1** **Privacy policy URL.** Host `PRIVACY_POLICY.md` as HTML on `nfcarchiver.com`. The bucket also hosts other apps, and the deploy workflow is confined to `app/` (see `webapp/README.md`). Either serve it under `https://nfcarchiver.com/app/privacy.html` through the existing `build:site`, or get explicit approval before touching anything outside `app/`.
- [ ] **5.2** App Privacy questionnaire: **Data Not Collected** (offline, no analytics). Check with the maintainer.
- [ ] **5.3** Age rating questionnaire, which should come out at the lowest rating.
- [ ] **5.4** Metadata: subtitle (≤30 chars), keywords (≤100 chars), description, promotional text. Start from `fastlane/metadata/android/<locale>/full_description.txt`; 7 locales exist (en, ru, tr, uk, ka, pl, be). Remove anything Android-only, such as the phone-radio Mifare claims: iPhone needs a Chameleon for Mifare Classic.
- [ ] **5.5** Screenshots: a 6.9" iPhone set (1320×2868 or 1290×2796); smaller sizes are scaled down. iPad isn't needed, because the app is iPhone only.
- [ ] **5.6** **Review notes plus a demo video.** The reviewer will have no NFC tags and no Chameleon, so without them a rejection under guideline 2.1 is likely. Include a short screen recording of archive → tap tags → restore, and explain the hardware requirement and that Mifare Classic needs a Chameleon Ultra.
- [ ] **5.7** Submit for review. Record any rejection and its fix in CLAUDE.md.

## Release hygiene (every iOS release)

- The version comes only from `pubspec.yaml` (`X.Y.Z+N`); the build number must increase for each upload.
- Release builds must keep the NFC entitlement: `Release.xcconfig` hardcodes it, and must not gain a `LocalOverrides` include.
