# Documentation site: design

Date: 2026-11-07. Status: awaiting the maintainer's approval.

## Why

NFC Archiver is going to the App Store. App Store Connect needs a public
**privacy policy URL** and a **support URL**, and TestFlight testers need a
guide that explains how the app behaves on their phone, especially the iPhone's
one-sheet-per-tag NFC flow, which surprises people. There is no site today: the
repo has no GitHub Pages, and the only privacy text is `PRIVACY_POLICY.md`.

The two audiences, in the maintainer's words: **testers and App Store
reviewers**. The site holds **a privacy policy plus a user guide**.

## Goals

- A public docs site with a user guide, a privacy policy and a support page.
- Served from **both** `https://nfcarchiver.com/docs/` (the address given to
  Apple) and GitHub Pages (`https://mezinster.github.io/nfcarchiver/`).
- In **all seven app languages**: en, ru, tr, uk, ka, pl, be.
- A privacy policy that matches what the app actually does today, including
  Bluetooth.

## Non-goals

- No marketing landing page, no App Store or F-Droid badges, no analytics.
- No per-language screenshots: **English screenshots on every language's
  pages, for now**.
- No app changes beyond the privacy screen (below).
- No changes to the web app's deploy (`deploy-webapp.yml`) or to anything
  under the bucket's `app/` prefix.

## Anti-goals (a failure even if it works)

- Anything that touches other prefixes in the `nfcarchiver.com` bucket, which
  hosts other applications.
- A privacy page that disagrees with the app's permission prompts (a reviewer
  compares them).
- Two privacy texts that can drift apart.
- Tracking scripts or third-party fonts loaded from the site. The site's own
  privacy has to match the policy it publishes.

## Decided by the maintainer

- **Audience:** testers and App Store reviewers.
- **Hosting:** both GitHub Pages and `nfcarchiver.com/docs/`. The `/docs` path
  on the main domain, not a `docs.` subdomain, and a second copy of the site
  lives there.
- **Languages:** all the languages the app supports.
- **Layout:** layout A, "classic docs": a sidebar with one page per topic and
  a language switch at the top. The **home page asks C's question, "What are
  you using?"**, with two choices, iPhone and Android, each opening that phone's
  page. On narrow screens the sidebar collapses into a menu.
- **Screenshots:** English everywhere.
- **Contact address:** `support@nfcarchiver.com`, on the support page and in
  the privacy policy. `nfcarchiver.com`'s MX records point to Fastmail. The
  maintainer owns making sure the mailbox or alias exists.

## Decided by Claude (the maintainer may override)

- **Generator:** MkDocs with the Material theme. It provides the sidebar, the
  phone menu, search and a per-language site with a switcher out of the box.
  Translations use `mkdocs-static-i18n` with one folder per language. Versions
  are pinned in `site-docs/requirements.txt`.
- **Source location:** `site-docs/` at the repo root, so it stays separate
  from `docs/`, which holds developer notes. The pages are Markdown.
- **URL shape:** English at the root (`/docs/privacy/`), other languages under
  their code (`/docs/ru/privacy/`). The URLs given to Apple are:
  - privacy: `https://nfcarchiver.com/docs/privacy/`
  - support: `https://nfcarchiver.com/docs/support/`
  - marketing URL, if one is wanted: `https://nfcarchiver.com/docs/`
- **Same commit, built twice.** Not every link MkDocs emits is relative: the
  404 page, the sitemap and the language switcher use `site_url`. So the build
  job runs `mkdocs build --strict` twice from the same commit:
  - once with `site_url: https://nfcarchiver.com/docs/`;
  - once with `https://mezinster.github.io/nfcarchiver/`, for example through
    an environment variable read with `!ENV`.

  Both copies are fully working, language switch included. The Pages copy
  sets its canonical link to `nfcarchiver.com/docs/` through a theme override,
  so search engines treat the owned domain as primary.
- **Folder URLs work on the main domain without CloudFront changes.** The
  CloudFront origin serves `index.html` for every folder. Live behaviour
  agrees: `/app` answers `302 → /app/`. So `use_directory_urls: true` (pretty URLs) is fine.
- **Both copies deploy together, from one manual workflow.** If they deployed
  separately, a privacy edit could be live on Pages while the URL given to
  Apple still served the old text. So there is a single `deploy-docs.yml`,
  manual (`workflow_dispatch`, `master` only, `dry_run` input).
  - It builds both trees once.
  - It deploys Pages (`actions/upload-pages-artifact` + `actions/deploy-pages`)
    and S3 from the same run.
  - Pages is enabled with "Source: GitHub Actions", a one-time step done via
    `gh api`.
  - CI separately builds the site (`mkdocs build --strict`) on PRs that touch
    `site-docs/**`, so broken links fail the PR, and deploys nothing.
- **The S3 half of `deploy-docs.yml`** is modelled on `deploy-webapp.yml`.
  - The build job has no AWS access (`permissions: {}`). It runs `pip install`
    and `mkdocs build --strict`, then uploads the `site/` tree as an artifact.
  - The deploy job runs in the `production` environment and gets AWS access
    through OIDC.
    - It runs `aws s3 sync --delete` into `s3://nfcarchiver.com/docs/`. HTML
      gets `no-cache`; other assets get `max-age=3600`.
    - It invalidates `/docs/*` and waits.
    - It then fetches `https://nfcarchiver.com/docs/` and `…/docs/privacy/`
      and requires a build marker (a `<meta name="nfar-docs-build"
      content="<sha>">` emitted through a theme override) to match the commit.
  - It needs a new repository variable, `S3_DOCS_PREFIX = docs/`. It reuses
    `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `S3_BUCKET` and
    `CLOUDFRONT_DISTRIBUTION_ID`.
  - No snapshot rollback: docs are low-stakes. To roll back, re-dispatch from a
    good commit, and document that.
- **AWS change, one-time, outside this repo.** The deploy role's permissions
  are extended to the `docs/` prefix outside this repository. No
  CloudFront change is needed. The specifics stay in that repository; see
  "What stays out of this public repo" below.
- **F-Droid safety:** neither new workflow touches `release.yml`, tags or
  `pubspec.yaml`.

## Site structure (English titles; every page is translated)

| Page | Content |
|---|---|
| Home | One line on what the app does, then "What are you using?" with iPhone and Android choices. |
| On iPhone | The phone writes and reads NTAG. An NFC sheet opens for **each tag**. A checkmark means the tag was read; a cross means a duplicate or unreadable tag. Wait ~3 s for the next sheet. Cancel stops the scan, and "Scan more tags" resumes it. The sheet times out after 60 s. Leaving the screen stops scanning. Mifare Classic is impossible with the iPhone's own NFC and needs a Chameleon Ultra (link). |
| On Android | The phone reads and writes NTAG and Mifare Classic directly, if it has the NXP Mifare feature (not all phones do). NFC must be switched on. The antenna is usually behind the upper back. |
| Archive a file | Pick a file, optional compression and password, tag type, write the tags one by one. What happens if a tag is too small. |
| Restore a file | Scan in any order, progress, duplicates, wrong password, then Open, Save or Share the result. |
| Tag types | NTAG213/215/216 and Mifare Classic 1K (the `NfcTagType` values): capacity per tag and how many tags a file needs, roughly. Which reader supports which. |
| Chameleon reader | What a Chameleon Ultra is, connecting it over Bluetooth, and why it is the only Mifare path on iPhone. Short; links to `docs/CHAMELEON.md` on GitHub for detail. |
| Troubleshooting | Session errors, "tag too small", "not writable", wrong password, CRC errors with rescan, nothing happens when tapping. |
| Privacy policy | See below. |
| Support | `support@nfcarchiver.com`, GitHub issues link, what to include (phone model, OS version, app version from the home screen footer, tag type). |

The facts on each page come from the code and `CLAUDE.md`, not memory. The
builder checks each claim, such as which media each platform supports, against
`lib/`.

## Privacy policy

- **Single source:** `site-docs/docs/privacy.md` (English, authoritative)
  plus six translations. Each translation carries a one-line note that the
  English text prevails.
- **`PRIVACY_POLICY.md`** becomes a short pointer to
  `https://nfcarchiver.com/docs/privacy/`, keeping the one-paragraph summary.
  Existing links to the file keep working.
- Content: the current policy's substance, with these changes:
  - "Last updated" set to the publish date.
  - A **Bluetooth** section: it is used only to connect to a Chameleon Ultra
    reader the user owns. No data leaves the device, and there is no location
    use. On Android, `BLUETOOTH_SCAN`/`CONNECT` are requested for this purpose.
  - **Permissions:** every permission the manifests declare is named, with
    its real use, so Play and F-Droid reviewers find a match.
    - NFC.
    - Bluetooth: `BLUETOOTH_SCAN`/`CONNECT` on Android, and
      `NSBluetoothAlwaysUsageDescription` on iOS, for the Chameleon only.
    - Storage (`READ`/`WRITE_EXTERNAL_STORAGE`): "on older Android versions,
      to read the files you pick and save restored files". Files are otherwise
      chosen through the system file picker.

    (Claude's call: honest about the manifest without sounding broader than
    the app is.)
  - **Diagnostic logs** stay in memory on the device. Nothing is ever sent
    unless the user shares it themselves, for example a card inspection
    report.
  - **Contact:** `support@nfcarchiver.com`.
  - A line that the docs site itself sets no cookies and loads no trackers.
    Material's Google Fonts are disabled (`theme.font: false`), and search runs
    locally.

## The app's own privacy screen

The app shows a full policy on its `/privacy-policy` screen
(`lib/shared/widgets/privacy_policy_screen.dart`, text in
`privacyPolicyContent` in all seven ARB files). It is as outdated as
`PRIVACY_POLICY.md`, with no Bluetooth and no contact.

**The maintainer's decision: a summary plus a link to the site.** The screen
keeps a short summary in every language:
- offline, nothing collected or sent;
- NFC, Bluetooth for the Chameleon, files you pick;
- encryption happens on the device.

Below it, an "Open full policy" button opens
`https://nfcarchiver.com/docs/privacy/` for English, or
`…/docs/<code>/privacy/` for the app's current locale, in the browser.

- The full text then exists only on the site.
- A widget test pins the URL per locale, so a moved page fails CI.
- Opening a URL needs a launcher. `url_launcher` (BSD, F-Droid-safe) is the
  expected choice; the builder checks it against F-Droid's scanner and the
  existing plugins.
- **Order:** the site's privacy page must be live on `nfcarchiver.com`
  before a build with the new screen is uploaded.
- The new screen ships in the next TestFlight build (17) and the next Android
  release. That release needs a version bump and `17.txt` changelogs in all
  seven fastlane locales, and the push of its tag stays the maintainer's call.

## Screenshots

- English UI screenshots in `site-docs/docs/assets/screenshots/`, shared by
  every language.
- **Android** screenshots: the builder takes them from the emulator (see the
  memory note on `--no-enable-impeller`). These show screens, not NFC
  hardware.
- **iPhone** shots that only real hardware shows (the NFC sheet with a
  checkmark, the duplicate message): the maintainer takes them on the iPhone
  13 Pro when asked, near the end of the work. Pages ship with the image slot
  left out until those images exist, never with a broken image.

## Translations

The builder translates, the same way the app's ARB strings are translated.
The UI terms in the guide (button labels such as "Scan more tags") must match
the app's own strings in `lib/l10n/app_<locale>.arb`, so a tester sees the same
words on screen and in the guide.

## Constraints

- The repo is public, so Pages and Actions minutes are free.
- Workflows must keep the single `FLUTTER_VERSION: '…'` line in `release.yml`
  untouched (F-Droid's `sed`).
- Never commit `ios/Flutter/LocalOverrides.xcconfig.free-team`.
- Merging PRs and running the S3 deploy happen only when the maintainer asks.

## What stays out of this public repo

This repo is public. Workflow files, variable names and the deploy procedure
are public by nature and belong here: a contributor needs them, and the
security boundary is the OIDC trust condition, not secrecy. The following
never appear in commits, PR text, workflow logs or the site:

- the AWS account ID, role ARN, CloudFront distribution ID, and any resource
  names beyond the bucket name, which is the public domain anyway;
- the infrastructure repository's name, layout or contents, including which
  other projects share the deploy role or bucket;
- anything that maps the account: other domains, instances, log buckets.

The role ARN stays a secret, as today. Workflow steps never echo the
assumed-role identity or distribution ID (no `aws sts get-caller-identity`
in logs).

## Left to the builder

Page wording, Material palette (use the app's seed colour `#1976D2`), icons,
the exact MkDocs config, the order of plan steps, how CI's link check is wired.

## Done when

- The app's privacy screen shows the summary and opens the right per-locale
  URL, and the widget test pins it.

- `mkdocs build --strict` passes in CI for all seven languages.
- GitHub Pages serves the site.
- `deploy-docs.yml` dry run shows changes only under `docs/`; a real run serves
  `https://nfcarchiver.com/docs/privacy/` and `…/support/` with the matching
  build marker.
- The privacy URL and support URL are entered in App Store Connect. The
  maintainer does this.
