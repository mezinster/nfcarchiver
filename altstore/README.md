# AltStore PAL source

NFC Archiver is distributed in the EU through [AltStore PAL](https://altstore.io) from an Apple Alternative Distribution Package (ADP).

| URL | What |
|---|---|
| `https://nfcarchiver.com/altstore/source.json` | The source users add in AltStore PAL (Sources → +) |
| `https://nfcarchiver.com/altstore/releases/<version>/` | The ADP, unzipped: `manifest.json`, `signature`, `variant/<id>.ipa` |
| `https://nfcarchiver.com/altstore/icon.png`, `header.png`, `screenshots/` | Listing images from the App Store asset set (`header.png` is the 3:2 search-results creative scaled to 1500×1000) |

## The package is never touched

Apple signs the ADP, and AltStore checks every file against `manifest.json`. Publish the files **byte for byte**. Don't reformat `manifest.json`, don't rename anything, don't re-zip or re-sign anything. The variants are FairPlay-encrypted, so they can't be unzipped. `publish.sh` checks each one against the SHA-256 and size in the manifest before uploading.

`signature` has no file extension. The site's CloudFront function normally treats an extension-less path as a folder and redirects it. `/altstore/` is exempt from that rule (`FILE_ONLY_PREFIXES` in the terraform repo's `websites/functions/directory-index.js`). Without the exemption, AltStore gets a 302 instead of the signature.

## Releasing a new version

1. Get the processed ADP through the AltStore PAL REST API (`GET https://api.altstore.io/adps/<id>`). Its download link expires, so unzip the ADP and keep the zip.
2. In `source.json`, add a new entry at the **top** of `apps[0].versions` (AltStore treats the first entry as the latest):
   - `version` = the manifest's `shortVersionString`, `buildVersion` = its `bundleVersion`
   - `downloadURL` = `https://nfcarchiver.com/altstore/releases/<version>/manifest.json`
   - `size` = the size of any variant
   - `date` and release notes
3. Check `appPermissions`. AltStore refuses to install an app with an entitlement or `NS…UsageDescription` key that the source doesn't list. Declaring an extra one is harmless. Missing one blocks the install.
4. `python3 -I altstore/validate.py --adp <unzipped-adp>` checks the source against the documented format and the manifest (add `--online` to check every URL). AltStore publishes no schema; the script encodes its docs.
5. `aws login`, then `altstore/publish.sh <unzipped-adp> --dry-run`, then run it again without `--dry-run`. The script:
   - refuses to overwrite a release that's already published
   - uploads the package first and `source.json` last
   - invalidates the mutable files
   - downloads every file back over HTTPS and compares its SHA-256

To change only `source.json` or the listing images for a release that is already live, use `altstore/publish.sh <unzipped-adp> --source-only`.

## Federation (Explore AltStore)

`fediUsername` gives the source an automated account on explore.alt.store (`nfcarchiver` → `@nfcarchiver@alt.store`), created by `POST https://api.altstore.io/federate` with `{"source": "https://nfcarchiver.com/altstore/source.json"}`. **The username cannot be changed afterwards.** The endpoint takes only the source URL, with no documented authentication. So once a source carrying `fediUsername` is live, anyone could trigger federation: putting the key live means committing to the name.

## TLS

CloudFront uses the `TLSv1.3_2025` policy, so only TLS 1.3 is accepted. iOS (all PAL versions), current browsers and curl are fine. Windows PowerShell 5.1 works with its default `SystemDefault` protocol on Windows 11, but fails with "Could not create SSL/TLS secure channel" if a script pins `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'`, and always on Windows 10, whose SChannel has no TLS 1.3. Use `Tls13`, PowerShell 7, or `curl.exe`.

`marketplaceID` is the app's Apple ID (`6831653857`), not the version ID.
