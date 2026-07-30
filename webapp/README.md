# NFC Archiver — Web

A browser port of [NFC Archiver](../README.md). It runs entirely client-side
(no server, no upload, no tracking) and uses a **Chameleon Ultra** over **Web
Bluetooth** to read and write NFAR archives on physical NFC cards from a Chromium
browser.

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
- **Diagnose card** — reads a card's raw UID + BCC (bypassing the reader's BCC
  check) to explain read failures.
- A branded, themed (light/dark), tabbed UI.

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
- **Deferred:** localization (7 locales), an IndexedDB-backed file manager (the Files
  tab is a placeholder), phone-native **Web NFC** writing (Android Chrome, no
  Chameleon — reuses `nfc/ndef.ts`), NTAG blank-tag CC formatting (factory/
  NDEF-formatted tags are assumed), and a device-disconnect path.

## License

MIT (see [`../LICENSE`](../LICENSE)).
