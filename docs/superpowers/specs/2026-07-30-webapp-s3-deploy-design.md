# Manually-triggered S3 + CloudFront delivery pipeline for the web app

**Date:** 2026-07-30
**Scope:** `webapp/` delivery only — a GitHub Actions workflow, a production build
script, a SHA build stamp, and a webapp job in CI. No changes to the NFAR core,
transports, or UI behaviour. The Flutter app is out of scope.

## Problem

The web app at `https://nfcarchiver.com/app/` is deployed by hand. The evidence
is `webapp/s3-upload/` — an untracked directory holding a copy of
`app/index.html` plus a `dist/main.js` bundle built ad hoc, uploaded manually to
S3. Three concrete defects follow from this:

1. **No production build exists.** `webapp/package.json` has `build` (`tsc`,
   typecheck only) and `app` (esbuild *dev server*). Neither emits a
   deployable bundle, so the deployed `main.js` was produced by an
   unrecorded command that nothing can reproduce.
2. **Nothing verifies a deploy.** There is no check that the bytes served by
   CloudFront are the bytes that were built, and no cache invalidation step, so
   a deploy can silently leave stale JavaScript at the edge.
3. **The webapp is not gated by CI.** `.github/workflows/ci.yml` runs Flutter
   analyze/test only. The webapp's 159 Node tests have never run on a PR, so
   the code being hand-deployed is code no automated gate has seen.

A fourth risk is environmental: the bucket `nfcarchiver.com` hosts **several
applications**, and `/app/` is one prefix inside it. A hand-run `aws s3 sync
--delete` against the wrong prefix would delete another application.

## Decisions (confirmed with user)

1. **Trigger:** `workflow_dispatch` only. Never on push or tag.
2. **Credentials:** GitHub OIDC federation. No long-lived AWS keys anywhere.
3. **Approval:** none. The manual trigger is the only gate — the `production`
   GitHub Environment carries **zero required reviewers** and exists solely to
   (a) pin the OIDC trust policy on `environment:production` and (b) restrict
   deploys to `master` via its deployment-branches rule.
4. **Verification:** pre-flight (tests, build, bundle sanity) plus post-deploy
   verification through the public domain, including a commit-SHA match.
5. **On verification failure:** automatic rollback to the previous live files,
   then fail the run.
6. **CI:** add a webapp test job to `ci.yml` so PRs gate the Node tests.
7. **`webapp/s3-upload/`:** deleted. The pipeline builds into a fresh gitignored
   directory; a stale hand-copied bundle invites deploying the wrong bytes.

## Architecture

Two jobs. The credential-bearing job does the minimum possible work.

```
workflow_dispatch (branch/tag selector + dry_run checkbox)
│
├── job: build ─────────────────── permissions: {}   (no AWS access at all)
│     node 22 · npm ci · npm test · npm run build:site
│     esbuild stamps the commit SHA into the bundle
│     bundle sanity checks
│     └─ upload-artifact: site/
│
└── job: deploy ───────────────── environment: production
      needs: build                permissions: { id-token: write, contents: read }
      download-artifact · aws-actions/configure-aws-credentials (assume role)
      1. snapshot   s3 sync s3://$BUCKET/app/ → ./previous/
      2. upload     s3 sync ./site/ → s3://$BUCKET/app/ --delete   (2 passes)
      3. invalidate /app/*  → wait for status Completed
      4. healthcheck https://nfcarchiver.com/app/
      5. on failure of 3 or 4 → restore ./previous/ --delete, invalidate, fail
```

**Why two jobs.** The build job runs `npm ci`, which executes third-party
package code. It holds no AWS token, so a compromised dependency cannot reach
S3. The deploy job never builds anything; it uploads bytes from an artifact.

**Concurrency.** `group: deploy-webapp`, `cancel-in-progress: false`. Two
overlapping deploys must never interleave their syncs, and cancelling a run
mid-sync would strand `app/` in a half-updated state. Queueing is correct here;
cancellation is not.

## Component boundaries

Four units, each independently understandable and separately testable:

| Unit | Purpose | Depends on |
|---|---|---|
| `webapp/scripts/build-site.ts` | Bundle `app/main.ts` + stage `index.html` into `site/`. Emits nothing else. | esbuild JS API, `BUILD_SHA` env var |
| `webapp/scripts/healthcheck.ts` | Given a base URL and expected SHA, assert the live deploy is correct. Exit 0/1. | `fetch` only |
| `.github/workflows/deploy-webapp.yml` | Orchestrate: build → upload → invalidate → verify → rollback. | the two scripts, AWS CLI |
| IAM role + policies | Bound what the workflow *can* do, independently of what it *does*. | — |

The healthcheck is a standalone script rather than inline YAML because it
decides whether to roll back; it must be readable and testable on its own.

Both scripts are TypeScript compiled by the existing `tsc` step and run from
`dist/scripts/`, matching the idiom `test/write_ts_fixtures.ts` already
establishes. `tsconfig.json` gains `"scripts/**/*.ts"` in `include`; `rootDir`
is already `.`, so the output lands at `dist/scripts/` with no other changes.
This keeps the healthcheck importable by a normal `test/*.test.ts` file, so it
is covered by `npm test` like everything else.

## Build: `npm run build:site`

New script `webapp/scripts/build-site.ts`, run by `npm run build:site`
(`tsc && node dist/scripts/build-site.js`). Uses the esbuild **JS API** (not the
CLI) because `--define` with a quoted string value is unreliable across shells.

```
site/
  index.html          ← copied verbatim from app/index.html
  dist/main.js        ← esbuild bundle of app/main.ts
```

- `bundle: true`, `format: 'esm'`, `platform: 'browser'`
- `define: { __BUILD_SHA__: JSON.stringify(process.env.BUILD_SHA ?? 'dev') }`
- **Minified** (`minify: true`), matching the hand-built bundle already deployed
  and validated on real hardware — that one is minified (176,813 B across 22
  lines). An unminified build would be the deviation: it comes out at 296,772 B,
  68% larger. With minification on, the reproducible build lands within 21 bytes
  of the deployed artifact, the delta being exactly the added SHA stamp.
- Output directory `webapp/site/` is gitignored.

`index.html` is copied verbatim, unmodified. It already references
`./dist/main.js` relatively (`app/index.html:167`), so the `site/` tree is
self-contained and position-independent — which is what makes it copyable to a
prefix and restorable from a snapshot.

### SHA stamping

`webapp/app/version.ts` gains a build stamp beside the existing `APP_VERSION`:

```ts
declare const __BUILD_SHA__: string | undefined;
export const APP_VERSION = '0.1.0';
export const BUILD_SHA = typeof __BUILD_SHA__ === 'undefined' ? 'dev' : __BUILD_SHA__;
```

The `typeof` guard is deliberate: an undeclared identifier is safe under
`typeof`, so the module still loads under `node --test` and under
`npm run app`, where no `define` is applied. `about-panel.ts` renders
`Web version 0.1.0 (a1b2c3d)`.

This is what makes a deploy *verifiable*. A 200 response proves S3 holds
something; a SHA match proves it holds **this build** and that no edge is still
serving the previous one.

### Bundle sanity checks (in the build job, before uploading)

Fail fast, while no credentials are in scope and nothing has been touched:

1. `site/index.html` and `site/dist/main.js` both exist and are non-empty.
2. `site/dist/main.js` contains the short commit SHA (proves `define` applied).
3. `site/index.html` contains `./dist/main.js` (proves the entry point resolves).

## Upload and cache headers

Two sync passes, because the two file types need different `Cache-Control`:

| Object | `Cache-Control` | `Content-Type` |
|---|---|---|
| `index.html` | `no-cache` | `text/html; charset=utf-8` |
| `dist/main.js` | `public, max-age=3600` | `text/javascript; charset=utf-8` |

Pass 1 syncs everything except `index.html` with the long header and `--delete`;
pass 2 uploads `index.html` with `no-cache`. `index.html` is written **last** so
the entry point never points at a bundle that has not landed yet.

Content types are set **explicitly** rather than relying on S3's guessing. This
project has already been bitten by MIME detection: per `CLAUDE.md`, Android's
`ContentResolver` reporting `application/octet-stream` made strict apps refuse
to send shared files, which is why every `Share.shareXFiles` call now passes an
explicit type. The same discipline applies at the CDN edge.

`main.js` has a fixed filename, so **correctness comes from the invalidation,
not the TTL**. Content-hashed filenames (`main-<hash>.js` with
`max-age=31536000, immutable`) would be strictly better and would make
invalidation unnecessary, but require rewriting `index.html` at build time.
`index.html` is currently a hand-authored file, and introducing templating is
not worth it for two files totalling ~180 KB. Recorded as a future option.

## Scoping: the shared-bucket constraint

`nfcarchiver.com` hosts multiple applications. Every operation is prefix-bound,
and the IAM policy makes an out-of-scope operation *fail* rather than merely
being absent from the workflow:

| Operation | Scope |
|---|---|
| `s3 sync --delete` | `s3://nfcarchiver.com/app/` — `--delete` only considers keys under this prefix |
| IAM object actions | `arn:aws:s3:::nfcarchiver.com/app/*` |
| IAM `s3:ListBucket` | bucket ARN with `s3:prefix` condition `app/*` |
| Invalidation paths | `/app/*` — never `/*`, so other applications' caches survive |

Defence in depth: correct paths in the workflow, plus a policy under which the
wrong path cannot succeed.

## Invalidation

`aws cloudfront create-invalidation --paths '/app/*'`, then poll
`get-invalidation` until status is `Completed` (bounded wait, ~5 min max). The
healthcheck must not run before propagation finishes, or it would test the old
edge copy and trigger a spurious rollback.

## Healthcheck

`node dist/scripts/healthcheck.js <baseUrl> <expectedSha>`, run after invalidation
completes, against the **public domain** — exercising DNS → CloudFront → S3
rather than just the origin:

1. `GET /app/` → 200 and `content-type` starts with `text/html`
2. `GET /app/dist/main.js` → 200 and `content-type` contains `javascript`
3. the body of `main.js` **contains the build marker `nfar-build:<expectedSha>`**

Check 3 matches a **prefixed sentinel, not the bare SHA**. Searching for the raw
SHA was tried first and is unsafe: the bundle is full of hex string constants
(CRC tables, APDU literals such as `"C82000000000"`), so a 7-hex-character
needle can match by coincidence — `0000000` genuinely occurs in an unrelated
constant, and the healthcheck passed a stale deploy as a result. The marker is
emitted by esbuild's `banner` option, which is written verbatim and survives
both minification and tree-shaking, so it is present regardless of whether any
application code references `BUILD_SHA`. Its format lives in one place,
`scripts/build-marker.ts`, imported by both the writer and the reader so the two
cannot drift.

Requests send `Cache-Control: no-cache`. Each check retries with exponential
backoff for up to ~60 s to absorb residual edge propagation, then fails.

Check 3 is the load-bearing one. Checks 1 and 2 catch a broken upload or a
misconfigured content type; only check 3 distinguishes "the deploy worked" from
"an older version is still being served".

Unit tests cover the script against a local `http.createServer` stub: a passing
case, a wrong-marker case, a non-200 case, the backoff schedule, and a
regression case asserting that a SHA appearing only inside an unrelated hex
constant does **not** satisfy the check. A healthcheck that mis-fires either
triggers a needless rollback or — worse, as the bare-SHA search did — waves a
stale deploy through, so its own logic is worth testing.

## Rollback

Step 1 syncs the live files into `./previous/` on the runner before anything is
overwritten. If invalidation or the healthcheck fails, the workflow syncs
`./previous/` back with `--delete`, issues a second invalidation, and then fails
the run loudly. Two files, ~200 KB — effectively instant.

**No S3 bucket versioning.** That is a bucket-wide setting on a bucket shared
with other applications; changing its storage and lifecycle semantics for this
one prefix is disproportionate.

**Stated limitation.** If the runner dies between upload and healthcheck,
nothing auto-restores. Recovery is to re-dispatch the workflow from the last
good tag or commit — which is also the intended manual rollback path, and is one
click. This is accepted rather than engineered around.

## `dry_run` input

A boolean `workflow_dispatch` input, default `false`. When true: build and
sanity-check as normal, run `s3 sync --dryrun` to print the exact object-level
plan, then stop — no upload, no invalidation, no healthcheck, no rollback. This
makes the first real deploy inspectable before it writes to a bucket shared with
other applications.

## Configuration

Set once during setup. No value below is an AWS credential.

| Kind | Name | Value |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | role ARN — held as a secret so the account ID is masked in logs |
| Variable | `AWS_REGION` | bucket region |
| Variable | `S3_BUCKET` | `nfcarchiver.com` |
| Variable | `S3_PREFIX` | `app/` |
| Variable | `CLOUDFRONT_DISTRIBUTION_ID` | distribution serving `nfcarchiver.com` |
| Variable | `SITE_BASE_URL` | `https://nfcarchiver.com/app/` |

Values are supplied by the operator during the AWS setup steps below; the design
fixes only where they live.

## AWS setup (operator steps)

1. **IAM → Identity providers → Add provider → OpenID Connect**
   - Provider URL `https://token.actions.githubusercontent.com`
   - Audience `sts.amazonaws.com`

2. **Create role** `nfcarchiver-webapp-deploy` with this trust policy
   (substitute the account ID):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:mezinster/nfcarchiver:environment:production"
        }
      }
    }
  ]
}
```

   The `sub` condition is the entire security boundary. It must be
   `StringEquals` on that exact string — a wildcard would let other
   repositories assume this role.

3. **Attach** this least-privilege permission policy (substitute account ID and
   distribution ID):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AppPrefixObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::nfcarchiver.com/app/*"
    },
    {
      "Sid": "ListAppPrefixOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::nfcarchiver.com",
      "Condition": { "StringLike": { "s3:prefix": ["app", "app/*"] } }
    },
    {
      "Sid": "InvalidateAppPaths",
      "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::AWS_ACCOUNT_ID:distribution/DISTRIBUTION_ID"
    }
  ]
}
```

4. **Report back:** role ARN, bucket region, CloudFront distribution ID.

5. **Verify two bucket facts**, because they change the policy:
   - **Object ACLs.** If the bucket has ACLs *enabled* and serves objects via
     public-read ACLs (legacy website hosting) rather than a bucket policy with
     Origin Access Control, then `s3:PutObjectAcl` must be added above and the
     sync must pass `--acl public-read`. If ACLs are disabled (the modern
     default, OAC + bucket policy), the policy above is complete as written.
   - **`/app/` index resolution.** Confirm CloudFront resolves `/app/` to
     `/app/index.html`. It does today, so this is a sanity check — but if it
     works via a CloudFront Function or `index.html` fallback that the deploy
     could disturb, we need to know before the first run.

6. **GitHub → Settings → Environments → New environment `production`**
   - Required reviewers: **none**
   - Deployment branches: **selected branches → `master`**

## Repository changes

| # | File | Change |
|---|---|---|
| 1 | `webapp/scripts/build-site.ts` | new — production build |
| 2 | `webapp/scripts/healthcheck.ts` | new — post-deploy verification |
| 3 | `webapp/test/healthcheck.test.ts` | new — 3 cases against a local server stub |
| 4 | `webapp/package.json` + `tsconfig.json` | add `build:site` script; add `scripts/**/*.ts` to `include` |
| 5 | `webapp/app/version.ts` | add `BUILD_SHA` with `typeof` guard |
| 6 | `webapp/app/ui/about-panel.ts` | show the build SHA beside the version |
| 7 | `.github/workflows/deploy-webapp.yml` | new — the pipeline |
| 8 | `.github/workflows/ci.yml` | add a `webapp` job: node 22, `npm ci`, `npm test` |
| 9 | `webapp/.gitignore` | ignore `site/` |
| 10 | `webapp/s3-upload/` | delete |
| 11 | `webapp/README.md` | document the deploy workflow and the setup values |
| 12 | `CLAUDE.md` | note the deploy pipeline in the Web App section |

## Testing strategy

- **Existing suite must stay green:** 159 tests, run via `rm -rf dist && npm test`
  (the `tsc && node --test` chain does not clean stale compiled tests).
- **New unit tests:** healthcheck script — pass, wrong SHA, non-200.
- **Build script:** verified by the build job's own sanity checks on every run
  rather than by unit tests; its output is checked directly (files present,
  SHA present, entry-point reference present), which is stronger than mocking
  esbuild.
- **First live run:** dispatch with `dry_run: true` and read the `--dryrun`
  object plan before any real deploy.
- **Rollback path:** exercised deliberately once by dispatching with an
  intentionally wrong expected SHA, confirming the restore runs and the site
  stays on the previous version. Without this, rollback is untested code that
  only ever runs during an incident.

## Out of scope

- Content-hashed asset filenames and long-lived immutable caching.
- Staging or preview environments.
- Any change to NFAR format, transports, or app behaviour.
- Creating or reconfiguring the S3 bucket, CloudFront distribution, ACM
  certificate, or DNS — all already exist.
