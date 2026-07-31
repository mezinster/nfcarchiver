# NFC Archiver — Web

A browser port of [NFC Archiver](../README.md). It runs entirely client-side
(no server, no upload, no tracking) and reads/writes NFAR archives on physical
NFC cards from a Chromium browser, either via a **Chameleon Ultra** over **Web
Bluetooth** or, on Chrome for Android, the phone's own radio via **Web NFC**
— see [Readers](#readers) below.

The bytes it writes are identical to the Flutter app's, so archives are
**interoperable in both directions**: a card written on the phone restores in the
browser and vice versa, and an NTAG written in the browser is a standard NDEF tag
readable by any NFC phone.

## Requirements

- **Node ≥ 22** for tests/build (needs `crypto.subtle` and `CompressionStream` as
  globals). Use nvm: `source ~/.nvm/nvm.sh && nvm use --lts`.
- **A Chromium browser** (Chrome/Edge) on a machine with Bluetooth. Web Bluetooth
  is not available in Firefox or iOS Safari. **Inside WSL2 there is no Bluetooth**
  — run the browser on the Windows host and point it at the dev-server URL.
- **A Chameleon Ultra** with a charged battery and BLE firmware, plus the cards
  you want to write (Mifare Classic 1K with factory keys, or NTAG213/215/216).

## Quick start

```bash
cd webapp
source ~/.nvm/nvm.sh && nvm use --lts
npm install
npm test        # runs the full unit/integration suite (no hardware needed)
npm run app     # serves http://localhost:8000
```

Open `http://localhost:8000` in Chrome/Edge, click **Connect Chameleon**, then use
the **Archive** / **Restore** tabs. See [`HARDWARE_TESTING.md`](HARDWARE_TESTING.md)
for the manual real-device checklist (BLE pairing, round-trip, cross-read).

## Features

- **Two media, auto-detected:** Mifare Classic 1K (720 B payload/card) and
  NTAG213/215/216 (Type-2 / NDEF). The transport reads each tapped tag's SAK and
  routes to the right protocol; the Archive tab has a target-tag selector (with
  capacities) that sizes the chunking.
- **Archive files or text**, with GZIP compression and AES-256-GCM + PBKDF2
  encryption, filename preservation, and a live "≈ N cards" estimate.
- **Multi-archive restore:** scan a mixed pile of cards, see every detected archive
  (encryption status + completeness), and pick a complete one to restore.
- **Inspect card** — dumps the presented card in a modal: identity (ATQA, UID,
  BCC — computed manually, bypassing the reader's own BCC check, so malformed
  "magic" cards are still identifiable), the decoded NFAR chunk header with
  CRC32 verification, and a raw hex/ASCII view of every block or page. Rendered
  progressively as the ~64 BLE reads arrive; Copy/Download give a plain-text
  report. Read-only, and disabled while an archive write or scan owns the reader.
- A branded, themed (light/dark), tabbed UI.

## Readers

Two ways to talk to a card, behind the same `Transport` interface — pick one in
the device bar:

- **Connect Chameleon** (`AutoTransport`, over Web Bluetooth) — full raw access
  to both media types (Mifare Classic 1K and NTAG213/215/216). The only reader
  that can do **Inspect card**.
- **Use phone NFC** (`WebNfcTransport`, over the phone's own radio via the
  [Web NFC API](https://developer.mozilla.org/en-US/docs/Web/API/Web_NFC_API))
  — shown only when `NDEFReader` exists, which today means **Chrome on
  Android**; there's no Web NFC in desktop Chrome, Firefox, or iOS Safari.

Connecting either reader tears down the other first
(`teardownActiveReader()` in `app/ui/device.ts`), so only one is ever live.

Phone NFC's limits are the Web NFC API's, not a missing feature:

- **NDEF only, no raw access.** The API is `scan()`/`write()` over NDEF
  messages — nothing lower-level. That rules out **Mifare Classic** (not an
  NDEF format) and **Inspect card** (needs raw block/page reads); both are
  disabled in the UI while phone NFC is the active reader.
- **No capacity discovery.** Web NFC never exposes a tag's Capability
  Container, so chunk size can't be measured off the card the way the
  Chameleon path does. It's taken from the tag type explicitly picked in the
  target-tag selector instead, sized against that type's *factory* CC bytes —
  `webNfcChunkPayload()` / `ntagFactoryNdefCapacity()` in `src/nfc/type2.ts`
  (144 / 496 / 872 B for NTAG213/215/216) — never the larger raw-memory
  estimate `ntagChunkPayloadSize()` uses for the Chameleon path.
  Because that type is baked into the transport, changing the target-tag
  selector while phone NFC is active **rebuilds** the transport (through the
  same `teardownActiveReader()` hand-off); otherwise it would keep sizing
  chunks for the previously selected chip.
- **Identity can be missing.** Chrome reports an empty `serialNumber` for some
  cards and some Android builds. Both loops key their already-written /
  already-seen sets on the UID, so `WebNfcTransport.awaitTag()` rejects such a
  tap with `UnidentifiedTagError` instead of minting a UID: an empty one
  collides every such card onto one key (the archive would stall forever on
  card 2), and a random one would let the same card be written twice.

**Reader ownership.** Archiving, restore scanning and card inspection all
drive the same reader through the same `Transport`, and none of them tolerates
a second loop calling `awaitTag()` underneath it. `app/ui/reader-lock.ts` holds
one owner at a time: **Archive to cards** and **Scan cards** each grey the
other out (with a tooltip saying why), and **Inspect card** is disabled while
either runs. `release()` is owner-checked, so the subsystem that finishes first
cannot free a lock another still holds.

**Disconnect is deliberately never gated on that lock.** It is the app's only
universal escape hatch — the archive loop has no Stop control — and both loops
handle a mid-flight teardown cleanly, so it doubles as the way to abandon a
stuck write.

**Scan model.** `app/ui/browser-ndef-io.ts` (`BrowserNdefIO`) is the only file
that touches `NDEFReader`. It arms exactly one scan per connection —
`WebNfcTransport.connect()` calls `io.start()` once, up front, in the user's
gesture, so a refusal surfaces at the **Use phone NFC** button rather than
inside a scan loop — and that single scan is reused for every card for the
rest of the session; nothing ever calls `scan()` a second time on the same
reader. A reading that arrives with no `awaitReading()` call waiting for it
(the gap between one card finishing and the loop asking for the next) is held
for two seconds and served to whichever call comes next, then discarded.
`app/ui/archive-orchestrator.ts` and `app/ui/restore-panel.ts` both pace their
retry loops to at least 250 ms/iteration and stop after five consecutive
failures of the *same* error name, via `ensureMinInterval` / `FailureBreaker`
in `src/loop-guards.ts`. Neither counts `TagTimeoutError`,
`OverwriteRequiredError`, or an abort against that limit — waiting for the
user to tap is not failing. The restore loop additionally excludes
`UnsupportedTagError`: a restore pile legitimately contains foreign cards, so
tapping several while sorting a stack is normal use. The archive loop counts
`UnsupportedTagError` like any other failure, because a wrong-media tap during
an active write is a genuine failure to progress.

This replaces an earlier, real production incident: the previous version of
`awaitReading()` called `scan()` again on every call, which aborted the still-live
scan and re-armed the same `NDEFReader` in the same tick — a call that rejects
*synchronously* on Chrome. The unthrottled retry loop around it then spun
tightly enough to lock up the renderer (186% CPU, one `setReaderMode` call
against eight tag discoveries in logcat) so hard the user couldn't press Stop
or switch tabs on a Pixel 8 Pro. Abort itself was never the problem.

Kept from before, still true: the `DOMException` → `CardCapacityError` mapping
(`NotSupportedError` / `NetworkError` on a write that doesn't fit) is written
from the Web NFC specification, not from an observed Chrome session, and may
not match what Chrome actually raises for an undersized card.

**Still unproven on real hardware:** whether `scan()` succeeds at all on a
phone, and whether `onreading` then fires repeatedly off that one persistent
scan across many taps, the way the whole design assumes. Treat both as open
questions until validated on an Android phone running Chrome;
[`HARDWARE_TESTING.md`](HARDWARE_TESTING.md) does not yet have a phone-NFC
checklist (it's Chameleon-only today).

## Localization

Seven locales, matching the Flutter app's language set: English (`en`), Russian
(`ru`), Turkish (`tr`), Ukrainian (`uk`), Georgian (`ka`), Polish (`pl`), and
Belarusian (`be`). Catalogues live in `app/i18n/`:

- `en.ts` is the schema — it exports `en` and `type Messages = typeof en`. Every
  other catalogue is declared `const xx: Messages = {…}`, so adding a key to
  `en.ts` breaks `tsc` on the other six until it's translated everywhere; the
  compiler is the completeness gate, not a script.
- `plural.ts` wraps `Intl.PluralRules` for the languages with more plural forms
  than English's two.
- `index.ts` is the locale registry: detection from `navigator.languages`, a
  manual override persisted at `localStorage['nfar-lang']` via the `<select
  id="lang">` in the header, and the live `t` binding consumed throughout `app/`.
- `dom.ts` applies static text through `data-i18n` / `data-i18n-placeholder` /
  `data-i18n-title` attributes in `app/index.html`. `test/i18n.test.ts` reads
  that HTML and asserts every `data-i18n` key resolves against the catalogue, so
  markup and translations can't silently drift apart.

Deliberately untranslated: Log tab entries and the card-inspection report body
(`src/inspect/`) — both are meant to be pasted verbatim into bug reports, so
English is more useful there than a translation. Also untranslated: the app
name, chip designations (NTAG213/215/216, Mifare Classic 1K), and log-level
names.

**`t` is a live ESM binding, reassigned on language change.** Reading `t.key`
inside a function always sees the current language. Destructuring it (`const {
archiveTitle } = t`) or capturing it in a module-level constant snapshots one
language permanently — `about-panel.ts` had exactly this bug and was
restructured to build its sections per render instead of once at import time.

## Architecture

Vanilla TypeScript, bundled by esbuild. No UI framework; the only runtime
dependency is `chameleon-ultra.js` (MIT), confined to two files.

```
webapp/
  src/                         # dependency-free core (web-platform globals only)
    crc32 · chunk · chunker · crypto · gzip · pipeline   # byte-compatible NFAR core
    filename.ts                # Android-compatible filename wrapper
    mifare/card-layout.ts      # chunk ↔ Mifare Classic 1K blocks (47 usable = 752 B)
    nfc/ndef.ts, nfc/type2.ts  # NDEF MIME record + Type-2 TLV framing for NTAG
    inspect/                   # read-only card inspector core
      card-dump.ts             # raw per-block/page dump of a Classic or NTAG card
      nfar-describe.ts         # tolerant NFAR header decode (reports, never throws)
      hex-view.ts              # text rendering of a dump + header for the dialog/report
    transport/                 # Transport seam + implementations
      transport.ts             # Transport interface + typed errors
      chameleon-device.ts      # ChameleonDevice seam (scanTag, transceive14a, block R/W)
      chameleon-ble.ts         # Mifare Classic transport
      ntag-transport.ts        # NTAG (Type-2/NDEF) transport
      auto-transport.ts        # routes each tag by SAK → Classic or NTAG
      sdk-chameleon-device.ts  # the SDK adapter (imports chameleon-ultra.js)
  app/                         # UI (thin DOM glue over the controllers)
    controller.ts              # DOM-free archive/restore state machines (tested)
    estimate.ts                # live card-count estimate
    i18n/                      # locale catalogues + registry; en.ts is the schema
    ui/                        # shell (tabs+theme), device (owns transport), panels
  test/                        # node:test suites + FakeChameleon + interop fixtures
```

The core (`src/` minus `transport/sdk-chameleon-device.ts`) uses only web-platform
globals, so the same files run in the browser and under `node --test`. A
`FakeChameleon` simulates both Mifare Classic and NTAG media, so every transport is
fully tested without hardware.

## Testing

- `npm test` — the full suite (NFAR core, codecs, transports vs the fake device,
  controllers, end-to-end archive→cards→restore for both media).
- **Cross-language interop** (proves phone↔browser byte-compatibility): from the
  repo root, `dart run tool/generate_web_fixtures.dart` then, after `npm run
  fixtures`, `dart run tool/verify_web_fixtures.dart` — the Dart side uses the
  Flutter app's production services, so a passing run is a real interop proof.
- The NDEF/Type-2 byte formats are pinned by byte-exact unit tests (the cross-compat
  guard); a real phone reading a Chameleon-written NTAG is a manual checklist item.

## Deployment

The app is served from `https://nfcarchiver.com/app/` — the `app/` prefix of the
`nfcarchiver.com` S3 bucket, behind CloudFront. The bucket hosts other
applications, so **every deploy operation is confined to that prefix**.

Deploys are manual, from `master` only:

```bash
gh workflow run deploy-webapp.yml --ref master                  # deploy
gh workflow run deploy-webapp.yml --ref master -f dry_run=true  # plan only
```

`dry_run` prints the object-level `aws s3 sync --dryrun` plan and uploads
nothing. Use it whenever the bucket or prefix configuration might have changed —
on a shared bucket, the plan is where a prefix mistake becomes visible instead of
becoming an aftermath.

What the workflow does:

1. **build job** (`permissions: {}`, no AWS access): `npm ci`, the full test
   suite, then `npm run build:site`, which stamps the short commit SHA into the
   bundle and asserts its own output. It publishes two artifacts — the
   deployable `site/` tree and the compiled healthcheck.
2. **deploy job** (OIDC credential, ~1 h lifetime): snapshots the live files for
   rollback, uploads assets with `max-age=3600` then `index.html` with
   `no-cache`, invalidates `/app/*` and waits for completion, then runs the
   healthcheck against the public URL.
3. On verification failure it restores the snapshot with the original headers,
   re-invalidates, and fails the run.

The split exists because the build job executes third-party package code via
`npm ci`. It holds no AWS token, so a compromised dependency cannot reach S3; the
deploy job never builds anything.

### How a deploy is verified

`scripts/build-site.ts` emits an esbuild **banner** — `/* nfar-build:<sha> */` —
and the healthcheck requires the served bundle to carry that exact marker. A 200
alone would only prove S3 holds *something*, not that CloudFront stopped serving
the previous version.

The marker is a prefixed sentinel rather than the bare SHA for a concrete
reason: the bundle is full of hex string constants (CRC tables, APDU literals
such as `"C82000000000"`), so a 7-hex-character needle can match by coincidence
and wave a stale deploy through. Its format lives once in
`scripts/build-marker.ts`, imported by both the writer and the reader so the two
cannot drift. `test/healthcheck.test.ts` pins the collision case.

The About tab shows the deployed SHA, so you can confirm what is live by eye.

To build locally without deploying:

```bash
BUILD_SHA=$(git rev-parse --short=7 HEAD) npm run build:site   # -> site/
```

### Rolling back

Re-dispatch the workflow from the last good commit:

```bash
gh workflow run deploy-webapp.yml --ref <good-sha-or-tag>
```

Automatic rollback only covers a *failed healthcheck* within a run. If the
runner itself dies between upload and verification, nothing restores
automatically — re-dispatch as above. A bug that verifies fine is likewise not
caught; the healthcheck proves which bytes are live, not that they are correct.

### Configuration

Set once on the repository, in the `production` environment. Only the role ARN
is a secret, and only so the account ID is masked in logs.

| Kind | Name | Value |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | IAM role assumed via OIDC |
| Variable | `AWS_REGION` | `eu-central-1` |
| Variable | `S3_BUCKET` | `nfcarchiver.com` |
| Variable | `S3_PREFIX` | `app/` (trailing slash required) |
| Variable | `CLOUDFRONT_DISTRIBUTION_ID` | distribution serving the domain |
| Variable | `SITE_BASE_URL` | `https://nfcarchiver.com/app/` |

The five non-credentials are **variables, not secrets, deliberately**. GitHub
redacts a secret's text wherever it appears in a log, by substring match — with
`app/` as a secret, every mention of `webapp/` would print as `web***`, and the
healthcheck's own output would read `healthy: *** is serving build …`. Masking
non-secrets destroys exactly the diagnostics a failed deploy needs.

There are no long-lived AWS keys anywhere. The `production` environment carries
no required reviewers, so a deploy never waits for approval; it exists to pin the
OIDC trust policy on `environment:production` and to restrict deploys to
`master`. The trust policy's `sub` condition —
`repo:mezinster/nfcarchiver:environment:production`, `StringEquals`, no
wildcard — is the entire security boundary. Do not use the IAM console's
web-identity role wizard on this role: it tends to emit a trust policy with only
an `aud` condition, which would let any repository on GitHub assume it.

The IAM permission policy allows object actions on
`arn:aws:s3:::nfcarchiver.com/app/*`, `ListBucket` on the bucket under an
`s3:prefix` condition, and `CreateInvalidation`/`GetInvalidation` on the one
distribution. Nothing else — so a wrong path in the workflow fails rather than
damaging a neighbouring application.

## Notes & known follow-ups

- `chameleon-ultra.js` validates arguments at runtime in ways the type-checker can't
  see: its `Buffer.isBuffer` rejects plain `Uint8Array` (the adapter converts with
  `Buffer.from`), and `cmdHf14aScan()` throws on an empty field. The
  `ChameleonDevice` seam absorbs these.
- Marginal RF coupling (a card pressed flat vs a few mm off the reader) can make the
  scan return transient BCC/parity/collision errors; the transport treats those as
  "no tag yet" and keeps polling.
- **Deferred:** an IndexedDB-backed file manager (the Files tab is a
  placeholder) and NTAG blank-tag CC formatting (factory/NDEF-formatted tags
  are assumed).

## License

MIT (see [`../LICENSE`](../LICENSE)).
