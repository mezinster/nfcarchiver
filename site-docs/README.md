# NFC Archiver documentation site

The user guide, privacy policy and support page, in the app's seven languages,
built with MkDocs + Material. One source tree is built twice:

- **`nfcarchiver.com/docs/`** — the copy the App Store listing links to
  (`https://nfcarchiver.com/docs/privacy/`, `https://nfcarchiver.com/docs/support/`);
- **`mezinster.github.io/nfcarchiver/`** — a GitHub Pages mirror whose canonical
  links point back at `nfcarchiver.com/docs/`.

English lives at the root, every other language under its code
(`/docs/ru/privacy/`). The language list comes from the app's
`lib/l10n/app_*.arb` files.

## Preview

```bash
cd site-docs
python3 -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements.txt
mkdocs serve
```

## Build

Both copies, from `site-docs/`, exactly as CI and the deploy build them:

```bash
DOCS_BUILD_SHA=$(git rev-parse HEAD) mkdocs build --strict -d site/main
DOCS_BUILD_SHA=$(git rev-parse HEAD) DOCS_SITE_URL=https://mezinster.github.io/nfcarchiver/ \
  mkdocs build --strict -d site/pages
```

`DOCS_BUILD_SHA` is stamped into every page as
`<meta name="nfar-docs-build" content="…">`; the deploy checks the live pages
for it.

## Checks

From the repository root:

```bash
python site-docs/check_site.py                     # sources: locales, page parity, contact
python site-docs/check_site.py --built site-docs/site/main  --base /docs/        --sha "$(git rev-parse HEAD)"
python site-docs/check_site.py --built site-docs/site/pages --base /nfcarchiver/ --sha "$(git rev-parse HEAD)"
```

The built-tree check fails on any link that starts with `/` but not with that
copy's own base path. CI (`build-docs` in `ci.yml`) runs all of this on every
PR that touches the site; it deploys nothing.

## Deploy

Manual only, from `master`. Dry run first:

```bash
gh workflow run deploy-docs.yml --ref master -f dry_run=true   # print the S3 plan, upload nothing
gh workflow run deploy-docs.yml --ref master                   # deploy
```

`deploy-docs.yml` builds and checks both copies, syncs the main copy to
`s3://<bucket>/docs/` (non-HTML first, HTML last with `no-cache`), invalidates
`/docs/*`, and checks that the live pages carry this commit's build marker.
Only then does it deploy the Pages mirror and check it the same way.

The deploy refuses any S3 prefix that is not a single lower-case segment ending
in `/`, or that equals the web app's prefix — `sync --delete` would otherwise
delete a neighbouring site. The dry run also fails if any planned key falls
outside the target prefix.

## Roll back

Re-dispatch the workflow from a known good commit. The workflow (and the
`production` and `github-pages` environments) accept only `master`, so that
means: revert the bad change on `master`, then deploy again.

```bash
git revert <bad-commit>   # via a PR to master
gh workflow run deploy-docs.yml --ref master
```

## Configuration

Set in the `production` environment, as environment variables or secrets (the Pages URL is fixed in the workflow).

| Name | Kind | Meaning |
|---|---|---|
| `S3_DOCS_PREFIX` | variable | `docs/` — the key prefix the site is synced to |
| `DOCS_BASE_URL` | variable | `https://nfcarchiver.com/docs/` — where the deploy verifies the live site |
| `S3_BUCKET` | variable | bucket serving `nfcarchiver.com` (shared with the web app) |
| `S3_PREFIX` | variable | the web app's prefix; the docs prefix must differ from it |
| `AWS_REGION` | variable | region of the bucket |
| `CLOUDFRONT_DISTRIBUTION_ID` | secret | distribution serving the domain; an environment secret, so it is masked and never appears in the logs (the web app's workflow still reads a variable of the same name) |
| `AWS_DEPLOY_ROLE_ARN` | secret | role assumed via GitHub OIDC; there are no stored AWS keys |

The deploy role's permissions are managed outside this repository.
