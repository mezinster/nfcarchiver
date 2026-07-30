# Web app S3 + CloudFront delivery pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manually-triggered GitHub Actions workflow that builds `webapp/`, uploads it to the `app/` prefix of the `nfcarchiver.com` S3 bucket, invalidates CloudFront, verifies the live site is serving the exact bundle it just built, and rolls back automatically if it is not.

**Architecture:** Two jobs. The build job runs `npm ci` and the test suite with **zero AWS access**, stamps the commit SHA into the bundle, and publishes two artifacts (`site` = deployable files, `deploy-tools` = the compiled healthcheck). The deploy job holds the only AWS credential — obtained per-run via GitHub OIDC, never stored — downloads those artifacts, snapshots the live files for rollback, uploads with explicit cache/content-type headers, invalidates `/app/*`, and runs the healthcheck. Every AWS operation is bound to the `app/` prefix because the bucket hosts other applications.

**Tech Stack:** TypeScript + esbuild (JS API), Node 22, `node --test`, GitHub Actions, AWS CLI v2, S3, CloudFront, IAM OIDC federation.

**Spec:** `docs/superpowers/specs/2026-07-30-webapp-s3-deploy-design.md`

## Global Constraints

- **Node ≥ 22 required.** Locally, run `source ~/.nvm/nvm.sh && nvm use --lts` first — the shell default is Node 14.
- **Always `rm -rf dist && npm test`.** The `tsc && node --test` chain does not clean stale compiled tests.
- **All webapp commands run from `webapp/`.** Never the repo root.
- **No new runtime dependencies.** `esbuild` is already a devDependency (0.23.1). The scripts added here may use it and Node built-ins only.
- **Dependency fence:** `chameleon-ultra.js` may be imported ONLY in `src/transport/sdk-chameleon-device.ts` and `app/ui/device.ts`. Nothing in this plan touches either.
- **Action versions (verified current, pin exactly):** `actions/checkout@v7`, `actions/setup-node@v7`, `actions/upload-artifact@v7`, `actions/download-artifact@v8`, `aws-actions/configure-aws-credentials@v6`.
- **Prefix discipline:** every S3 path is `s3://$BUCKET/$PREFIX` where `PREFIX=app/` (with trailing slash); every invalidation path is `/app/*`. Never `/*`, never the bucket root.
- **Branch:** work on `feat/webapp-s3-deploy-pipeline` (already exists, PR #43). The spec commit `867b2da` is its first commit.
- **Blocked on the operator** for Task 4's live run only: `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `CLOUDFRONT_DISTRIBUTION_ID`. Tasks 1–3 and writing Task 4's YAML need none of them.

## File Structure

| File | Responsibility |
|---|---|
| `webapp/scripts/build-site.ts` | Produce a deployable `site/` tree and refuse to emit a bundle that lost its build stamp or entry-point reference. |
| `webapp/scripts/healthcheck.ts` | Given a base URL + expected SHA, decide whether the live deploy is correct. Pure logic + a thin CLI. |
| `webapp/test/healthcheck.test.ts` | Cover the healthcheck against a local HTTP stub. |
| `webapp/app/version.ts` | Own both version identifiers: `APP_VERSION` and the build-time `BUILD_SHA`. |
| `.github/workflows/deploy-webapp.yml` | Orchestrate build → upload → invalidate → verify → rollback. Holds no logic beyond sequencing and AWS CLI calls. |
| `.github/workflows/ci.yml` | Gain a `webapp` job so PRs run the Node tests. |

The healthcheck is a separate module — not inline YAML — because it decides whether to roll back. It must be readable and testable on its own.

---

### Task 1: Production build with a commit-SHA stamp

**Files:**
- Create: `webapp/scripts/build-site.ts`
- Modify: `webapp/app/version.ts` (whole file, 2 lines today)
- Modify: `webapp/app/ui/about-panel.ts:2` and `:6`
- Modify: `webapp/package.json` (scripts block)
- Modify: `webapp/tsconfig.json` (`include` array)
- Modify: `webapp/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `npm run build:site` (reads `BUILD_SHA` env var, default `dev`) emitting `webapp/site/index.html` + `webapp/site/dist/main.js`; and the export `BUILD_SHA: string` from `app/version.ts`.

- [ ] **Step 1: Add `scripts/` to the TypeScript project**

`webapp/tsconfig.json` — extend `include` only; leave `compilerOptions` untouched. `rootDir` is already `"."` and `outDir` is `"dist"`, so `scripts/foo.ts` compiles to `dist/scripts/foo.js` with no other change:

```json
  "include": ["src/**/*.ts", "app/**/*.ts", "test/**/*.ts", "scripts/**/*.ts"]
```

- [ ] **Step 2: Add the build stamp to `version.ts`**

Replace the entire contents of `webapp/app/version.ts`:

```ts
/** Web app version, shown in the About tab. Bump on release. */
export const APP_VERSION = '0.1.0';

/**
 * Commit SHA substituted at build time by scripts/build-site.ts via esbuild
 * `define`. Falls back to 'dev' when nothing substituted it — under
 * `npm run app` or `node --test`. `typeof` on an identifier that does not exist
 * at runtime is safe (it does not throw), which is what makes the fallback work
 * without polluting the global scope with a declaration.
 */
declare const __BUILD_SHA__: string | undefined;
export const BUILD_SHA: string = typeof __BUILD_SHA__ === 'undefined' ? 'dev' : __BUILD_SHA__;
```

- [ ] **Step 3: Surface the stamp in the About tab**

`webapp/app/ui/about-panel.ts` — line 2 becomes:

```ts
import { APP_VERSION, BUILD_SHA } from '../version.js';
```

and line 6 becomes:

```ts
    `Web version ${APP_VERSION} (${BUILD_SHA})`,
```

- [ ] **Step 4: Write the build script**

Create `webapp/scripts/build-site.ts`:

```ts
/**
 * Production build: bundles app/main.ts and stages a deployable site/ tree.
 * Run via `npm run build:site`, which compiles this file to
 * dist/scripts/build-site.js first.
 *
 * The commit SHA from BUILD_SHA is stamped into the bundle so that a deploy can
 * be verified end to end — see scripts/healthcheck.ts. The script asserts its
 * own output before exiting, so a bundle that lost its stamp or its entry-point
 * reference can never reach S3.
 */
import { build } from 'esbuild';
import { copyFile, mkdir, readFile, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// This file runs as dist/scripts/build-site.js, so webapp/ is two levels up.
const webappRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = join(webappRoot, 'site');

async function main(): Promise<void> {
  const sha = process.env.BUILD_SHA ?? 'dev';

  await rm(outDir, { recursive: true, force: true });
  await mkdir(join(outDir, 'dist'), { recursive: true });

  await build({
    entryPoints: [join(webappRoot, 'app', 'main.ts')],
    outfile: join(outDir, 'dist', 'main.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    // Minified, matching the bundle that has been validated on real hardware
    // (the previous hand-built deploy was minified: 177 KB / 22 lines).
    // Unminified would be the deviation here, not the safe default.
    minify: true,
    define: { __BUILD_SHA__: JSON.stringify(sha) },
    logLevel: 'info',
  });

  // index.html is copied verbatim. It references ./dist/main.js relatively, so
  // the site/ tree is self-contained and position-independent — which is what
  // makes it safe to copy to a prefix and to restore from a snapshot.
  await copyFile(join(webappRoot, 'app', 'index.html'), join(outDir, 'index.html'));

  const bundle = await readFile(join(outDir, 'dist', 'main.js'), 'utf8');
  const html = await readFile(join(outDir, 'index.html'), 'utf8');
  if (bundle.length === 0) throw new Error('bundle is empty');
  if (html.length === 0) throw new Error('index.html is empty');
  if (!bundle.includes(sha)) {
    throw new Error(`bundle does not contain BUILD_SHA "${sha}" — esbuild define did not apply`);
  }
  if (!html.includes('./dist/main.js')) {
    throw new Error('index.html does not reference ./dist/main.js');
  }

  console.log(`site/ built and verified — BUILD_SHA=${sha}, bundle ${bundle.length} B`);
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
```

- [ ] **Step 5: Wire up the npm script and gitignore the output**

`webapp/package.json` — add to `scripts`, keeping the existing entries:

```json
    "build:site": "tsc && node dist/scripts/build-site.js",
```

`webapp/.gitignore` — append a line so the build output is never committed:

```
site/
```

- [ ] **Step 6: Run the build and confirm it verifies its own output**

```bash
cd webapp
source ~/.nvm/nvm.sh && nvm use --lts
rm -rf dist site && BUILD_SHA=abc1234 npm run build:site
```

Expected: ends with `site/ built and verified — BUILD_SHA=abc1234, bundle <N> B`.

Then confirm the tree and the stamp:

```bash
find site -type f | sort
grep -c abc1234 site/dist/main.js
```

Expected: exactly `site/dist/main.js` and `site/index.html`; grep count ≥ 1.

- [ ] **Step 7: Prove the self-check actually fires**

These assertions are what stand between a broken bundle and production, so confirm they are not vacuous. Break the entry-point reference in the **source**, rebuild, then revert:

```bash
sed -i 's|./dist/main.js|./dist/WRONG.js|' app/index.html
BUILD_SHA=abc1234 npm run build:site; echo "exit=$?"
git checkout app/index.html
```

Expected: fails with `Error: index.html does not reference ./dist/main.js` and `exit=1`. The `git checkout` restores the file — confirm with `git status --short app/index.html` printing nothing.

Then confirm the stamp assertion fires, by substituting the wrong value. The
copy must live inside the tree or Node cannot resolve `esbuild`:

```bash
sed 's|JSON.stringify(sha)|JSON.stringify("wrong")|' dist/scripts/build-site.js > dist/scripts/bad-define.mjs
BUILD_SHA=abc1234 node dist/scripts/bad-define.mjs 2>&1 | grep -i Error
rm -f dist/scripts/bad-define.mjs
```

Expected: `Error: bundle does not contain BUILD_SHA "abc1234" — esbuild define did not apply`.

(Do **not** try this by renaming the `define:` key — esbuild's JS API rejects
unknown options outright, so it would fail for the wrong reason.)

Finally, rebuild cleanly so `site/` is not left holding a bad bundle:

```bash
BUILD_SHA=abc1234 npm run build:site | tail -1
```

- [ ] **Step 8: Confirm the existing suite still passes**

The `version.ts` change is imported by `about-panel.ts`, which is imported by `main.ts`:

```bash
rm -rf dist && npm test
```

Expected: `tests 159`, `pass 159`, `fail 0`.

- [ ] **Step 9: Confirm the dev server still works without a stamp**

This is the `typeof` fallback's only real test — the identifier is undeclared at runtime here:

```bash
npm run app
```

Expected: serves on `localhost:8000` with no console error. Open the About tab and confirm it reads `Web version 0.1.0 (dev)`. Stop with Ctrl-C.

- [ ] **Step 10: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/scripts/build-site.ts webapp/app/version.ts webapp/app/ui/about-panel.ts \
        webapp/package.json webapp/tsconfig.json webapp/.gitignore
git commit -m "feat(webapp): production build:site script with a commit-SHA build stamp

No production build existed — package.json had only tsc (typecheck) and the
esbuild dev server, which is why the deployed bundle was assembled by hand.

build-site.ts bundles app/main.ts into a self-contained site/ tree and asserts
its own output before exiting: non-empty files, the BUILD_SHA present in the
bundle, and index.html still referencing ./dist/main.js. A bundle that lost its
stamp therefore cannot reach S3.

BUILD_SHA is surfaced in the About tab and is what lets a post-deploy check
prove CloudFront is serving this build rather than merely serving something."
```

---

### Task 2: Healthcheck script

**Files:**
- Create: `webapp/scripts/healthcheck.ts`
- Create: `webapp/test/healthcheck.test.ts`

**Interfaces:**
- Consumes: the build marker from Task 1 — `nfar-build:<sha>`, emitted as an esbuild banner.
- Produces: `checkOnce(baseUrl: string, expectedSha: string, fetchImpl?: typeof fetch): Promise<CheckResult>`, `healthcheck(baseUrl: string, expectedSha: string, opts?: HealthcheckOptions): Promise<CheckResult>`, `interface CheckResult { ok: boolean; failures: string[] }`, and a CLI: `node dist/scripts/healthcheck.js <baseUrl> <expectedSha>` exiting 0 on healthy, 1 otherwise.

> **Implementation note (deviation from the code listed below).** The listed
> version searches the served bundle for the bare `expectedSha`. That was
> implemented, and Step 5's end-to-end check caught it passing a *stale* deploy:
> the bundle contains hex constants such as `"C82000000000"`, so the 7-character
> needle `0000000` matched by coincidence. As shipped, the check instead matches
> the prefixed sentinel `nfar-build:<sha>` emitted by esbuild's `banner` option,
> with the format defined once in `scripts/build-marker.ts` and imported by both
> `build-site.ts` and `healthcheck.ts`. A regression test covers the
> hex-constant collision. Read the shipped files, not the listings below, when
> touching this logic.

- [ ] **Step 1: Write the failing test**

Create `webapp/test/healthcheck.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { checkOnce, healthcheck } from '../scripts/healthcheck.js';

const SHA = 'abc1234';
const HTML = '<!doctype html><html><body>ok</body></html>';

/** Serve a fake deployed site; `bundle` and `jsStatus` are the knobs under test. */
async function serve(opts: { bundle: string; jsStatus?: number }): Promise<{ base: string; close: () => Promise<void> }> {
  const server: Server = createServer((req, res) => {
    if (req.url === '/app/dist/main.js') {
      const status = opts.jsStatus ?? 200;
      res.writeHead(status, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(status === 200 ? opts.bundle : 'not found');
      return;
    }
    if (req.url === '/app/' || req.url === '/app/index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(HTML);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('nope');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  return {
    base: `http://127.0.0.1:${port}/app/`,
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

test('healthy deploy: 200s, right content types, bundle carries the SHA', async () => {
  const s = await serve({ bundle: `console.log("build ${SHA}");` });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.deepEqual(r.failures, []);
    assert.equal(r.ok, true);
  } finally { await s.close(); }
});

test('stale edge: bundle served without the expected SHA fails', async () => {
  const s = await serve({ bundle: 'console.log("build 0000000");' });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.equal(r.ok, false);
    assert.ok(r.failures.some((f) => f.includes(SHA)), `expected a SHA failure, got ${JSON.stringify(r.failures)}`);
  } finally { await s.close(); }
});

test('missing bundle: a non-200 on main.js fails', async () => {
  const s = await serve({ bundle: '', jsStatus: 404 });
  try {
    const r = await checkOnce(s.base, SHA);
    assert.equal(r.ok, false);
    assert.ok(r.failures.some((f) => f.includes('404')), `expected a 404 failure, got ${JSON.stringify(r.failures)}`);
  } finally { await s.close(); }
});

test('healthcheck retries a failing check and reports the last result', async () => {
  const s = await serve({ bundle: 'console.log("build 0000000");' });
  const slept: number[] = [];
  try {
    const r = await healthcheck(s.base, SHA, {
      attempts: 3,
      firstDelayMs: 10,
      sleep: async (ms) => { slept.push(ms); },
    });
    assert.equal(r.ok, false);
    assert.deepEqual(slept, [10, 20], 'should back off between attempts, not after the last');
  } finally { await s.close(); }
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd webapp && rm -rf dist && npx tsc 2>&1 | head -3
```

Expected: FAIL — `Cannot find module '../scripts/healthcheck.js'` or `error TS2307`.

- [ ] **Step 3: Write the implementation**

Create `webapp/scripts/healthcheck.ts`:

```ts
/**
 * Post-deploy verification. Fetches the live site through its PUBLIC url — so
 * DNS, CloudFront and S3 are all exercised, not just the origin — and asserts
 * it is serving the bundle this run built.
 *
 *   node dist/scripts/healthcheck.js https://nfcarchiver.com/app/ <sha>
 *
 * A 200 only proves S3 holds something. The SHA match is the load-bearing
 * check: it proves the bundle is THIS build and that no edge is still serving
 * the previous one.
 */
import { pathToFileURL } from 'node:url';

export interface CheckResult {
  ok: boolean;
  failures: string[];
}

export interface HealthcheckOptions {
  attempts?: number;
  firstDelayMs?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
}

const NO_CACHE: Record<string, string> = { 'cache-control': 'no-cache', pragma: 'no-cache' };

/** One full pass. Collects every failure rather than stopping at the first, so
 *  a failing deploy reports everything wrong with it in one log. */
export async function checkOnce(
  baseUrl: string,
  expectedSha: string,
  fetchImpl: typeof fetch = fetch,
): Promise<CheckResult> {
  const failures: string[] = [];
  const base = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const bundleUrl = new URL('dist/main.js', base).toString();

  const html = await fetchImpl(base, { headers: NO_CACHE, redirect: 'follow' });
  if (html.status !== 200) failures.push(`GET ${base} -> ${html.status} (want 200)`);
  const htmlType = html.headers.get('content-type') ?? '';
  if (!htmlType.includes('text/html')) {
    failures.push(`GET ${base} content-type "${htmlType}" (want text/html)`);
  }

  const js = await fetchImpl(bundleUrl, { headers: NO_CACHE, redirect: 'follow' });
  if (js.status !== 200) failures.push(`GET ${bundleUrl} -> ${js.status} (want 200)`);
  const jsType = js.headers.get('content-type') ?? '';
  if (!jsType.includes('javascript')) {
    failures.push(`GET ${bundleUrl} content-type "${jsType}" (want javascript)`);
  }
  if (js.status === 200) {
    const body = await js.text();
    if (!body.includes(expectedSha)) {
      failures.push(`served bundle does not contain BUILD_SHA ${expectedSha} — an older version is still live`);
    }
  }

  return { ok: failures.length === 0, failures };
}

/** Retry with exponential backoff to absorb residual CloudFront propagation.
 *  Defaults total ~62s across 6 attempts. */
export async function healthcheck(
  baseUrl: string,
  expectedSha: string,
  opts: HealthcheckOptions = {},
): Promise<CheckResult> {
  const attempts = opts.attempts ?? 6;
  const fetchImpl = opts.fetchImpl ?? fetch;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  let delay = opts.firstDelayMs ?? 2000;
  let last: CheckResult = { ok: false, failures: ['no attempt was made'] };

  for (let i = 1; i <= attempts; i++) {
    try {
      last = await checkOnce(baseUrl, expectedSha, fetchImpl);
    } catch (e: unknown) {
      last = { ok: false, failures: [`request failed: ${String(e)}`] };
    }
    if (last.ok) return last;
    if (i < attempts) {
      console.error(`attempt ${i}/${attempts} failed:`);
      for (const f of last.failures) console.error(`  - ${f}`);
      console.error(`retrying in ${delay}ms`);
      await sleep(delay);
      delay *= 2;
    }
  }
  return last;
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  const [baseUrl, expectedSha] = process.argv.slice(2);
  if (!baseUrl || !expectedSha) {
    console.error('usage: node dist/scripts/healthcheck.js <baseUrl> <expectedSha>');
    process.exit(2);
  }
  const result = await healthcheck(baseUrl, expectedSha);
  if (result.ok) {
    console.log(`healthy: ${baseUrl} is serving build ${expectedSha}`);
    process.exit(0);
  }
  console.error('UNHEALTHY:');
  for (const f of result.failures) console.error(`  - ${f}`);
  process.exit(1);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd webapp && rm -rf dist && npm test 2>&1 | tail -12
```

Expected: `tests 163`, `pass 163`, `fail 0` (159 existing + 4 new).

- [ ] **Step 5: Verify the CLI end to end against the real build output**

This proves the two scripts agree on the stamp — the whole point of both:

```bash
rm -rf site && BUILD_SHA=abc1234 npm run build:site >/dev/null
npx --yes http-server site -p 8123 --silent &
sleep 1
node dist/scripts/healthcheck.js http://127.0.0.1:8123/ abc1234; echo "exit=$?"
node dist/scripts/healthcheck.js http://127.0.0.1:8123/ 0000000; echo "exit=$?"
kill %1
```

Expected: first invocation prints `healthy: ... serving build abc1234`, `exit=0`; second prints `UNHEALTHY` with the SHA failure and `exit=1`.

If `http-server` is unavailable offline, substitute `python3 -m http.server 8123 --directory site` and expect the same two outcomes.

- [ ] **Step 6: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/scripts/healthcheck.ts webapp/test/healthcheck.test.ts
git commit -m "feat(webapp): post-deploy healthcheck that verifies the served build

Asserts, through the public URL so DNS/CloudFront/S3 are all exercised: index
returns 200 as text/html, the bundle returns 200 as javascript, and the served
bundle contains the BUILD_SHA of this build. The SHA match is the load-bearing
one — a 200 only proves S3 holds something, not that an edge stopped serving
the previous version.

Retries with exponential backoff (~62s over 6 attempts) to absorb residual
invalidation propagation. Kept as a testable module rather than inline YAML
because its verdict triggers an automatic rollback: 4 tests cover healthy,
stale-SHA, missing-bundle and the backoff schedule."
```

---

### Task 3: Gate the webapp in CI

**Files:**
- Modify: `.github/workflows/ci.yml` (add a job after `analyze-and-test`)

**Interfaces:**
- Consumes: nothing from Tasks 1–2 (runs `npm test`, which now includes the healthcheck tests).
- Produces: nothing consumed later. Independent.

- [ ] **Step 1: Add the webapp job**

Append to `.github/workflows/ci.yml`, at the same indentation as the existing `build-android:` job. Deliberately **not** `needs:`-chained to the Flutter jobs — the webapp core is independent, so it should report separately and not wait on a Flutter build:

```yaml
  webapp:
    name: Web app core (TypeScript)
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Setup Node
        uses: actions/setup-node@v7
        with:
          node-version: '22'
          cache: 'npm'
          cache-dependency-path: webapp/package-lock.json

      - name: Install dependencies
        working-directory: webapp
        run: npm ci

      - name: Typecheck and run tests
        working-directory: webapp
        # rm -rf dist because the `tsc && node --test` chain does not clean
        # stale compiled tests.
        run: rm -rf dist && npm test
```

- [ ] **Step 2: Validate the YAML parses**

```bash
cd /home/mezinster/nfcarchiver
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(sorted(d['jobs'].keys()))"
```

Expected: `['analyze-and-test', 'build-android', 'webapp']`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run the webapp TypeScript suite on every PR

ci.yml was Flutter-only, so the webapp's Node tests had never gated a pull
request. Deploying code that no automated check has seen is the larger risk
next to the delivery pipeline itself.

Not chained to the Flutter jobs: the webapp core is independent and should
report separately rather than queue behind an Android build."
```

---

### Task 4: The deploy workflow

**Files:**
- Create: `.github/workflows/deploy-webapp.yml`

**Interfaces:**
- Consumes: `npm run build:site` + `BUILD_SHA` (Task 1); `dist/scripts/healthcheck.js <baseUrl> <sha>` (Task 2).
- Produces: nothing consumed by later tasks.

**Configuration this job reads** (set by the operator — see the AWS Setup appendix):

| Kind | Name |
|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` |
| Variable | `AWS_REGION`, `S3_BUCKET`, `S3_PREFIX`, `CLOUDFRONT_DISTRIBUTION_ID`, `SITE_BASE_URL` |

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/deploy-webapp.yml`:

```yaml
name: Deploy web app

# Manual only. Never on push or tag.
on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'Print the S3 sync plan and stop — uploads nothing'
        type: boolean
        default: false

# No ambient permissions anywhere. The deploy job opts in to id-token below.
permissions: {}

concurrency:
  # Queue, never cancel: a run cancelled mid-sync would leave app/ half-updated.
  group: deploy-webapp
  cancel-in-progress: false

jobs:
  build:
    name: Build & verify bundle
    runs-on: ubuntu-latest
    # This job runs `npm ci`, which executes third-party package code. It holds
    # no AWS credential, so a compromised dependency cannot reach S3.
    permissions: {}
    outputs:
      sha: ${{ steps.stamp.outputs.sha }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Setup Node
        uses: actions/setup-node@v7
        with:
          node-version: '22'
          cache: 'npm'
          cache-dependency-path: webapp/package-lock.json

      - name: Install dependencies
        working-directory: webapp
        run: npm ci

      - name: Typecheck and run tests
        working-directory: webapp
        run: rm -rf dist && npm test

      - name: Compute build stamp
        id: stamp
        run: echo "sha=$(git rev-parse --short=7 HEAD)" >> "$GITHUB_OUTPUT"

      - name: Build site
        working-directory: webapp
        env:
          BUILD_SHA: ${{ steps.stamp.outputs.sha }}
        # build-site.ts asserts its own output: non-empty files, BUILD_SHA
        # present in the bundle, index.html still pointing at ./dist/main.js.
        run: npm run build:site

      - name: Upload deployable site
        uses: actions/upload-artifact@v7
        with:
          name: site
          path: webapp/site/
          if-no-files-found: error
          retention-days: 7

      - name: Upload healthcheck tool
        # Shipped as its own artifact so the credentialed job can verify the
        # deploy without checking out the repo or running `npm ci`.
        uses: actions/upload-artifact@v7
        with:
          name: deploy-tools
          path: webapp/dist/scripts/healthcheck.js
          if-no-files-found: error
          retention-days: 7

  deploy:
    name: Deploy to S3 + CloudFront
    needs: build
    runs-on: ubuntu-latest
    # Zero required reviewers — this exists to pin the OIDC trust policy on
    # `environment:production` and to restrict deploys to master.
    environment: production
    permissions:
      id-token: write   # mint the OIDC token used to assume the AWS role
      contents: read
    env:
      BUCKET: ${{ vars.S3_BUCKET }}
      PREFIX: ${{ vars.S3_PREFIX }}
      DIST_ID: ${{ vars.CLOUDFRONT_DISTRIBUTION_ID }}
      BASE_URL: ${{ vars.SITE_BASE_URL }}
      BUILD_SHA: ${{ needs.build.outputs.sha }}
    steps:
      - name: Download deployable site
        uses: actions/download-artifact@v8
        with:
          name: site
          path: site

      - name: Download healthcheck tool
        uses: actions/download-artifact@v8
        with:
          name: deploy-tools
          path: tools

      - name: Setup Node
        uses: actions/setup-node@v7
        with:
          node-version: '22'

      - name: Assume the AWS deploy role via OIDC
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
          role-session-name: gha-webapp-deploy-${{ github.run_id }}

      - name: Show what would be uploaded, then stop
        if: ${{ inputs.dry_run }}
        run: |
          set -euo pipefail
          aws s3 sync ./site/ "s3://${BUCKET}/${PREFIX}" --delete --dryrun
          echo "dry_run: nothing was uploaded."

      - name: Snapshot the live files for rollback
        id: snapshot
        if: ${{ !inputs.dry_run }}
        run: |
          set -euo pipefail
          mkdir -p previous
          aws s3 sync "s3://${BUCKET}/${PREFIX}" ./previous/
          echo "snapshot taken:"
          find previous -type f | sort

      - name: Upload assets (long-lived cache)
        id: upload_assets
        if: ${{ !inputs.dry_run }}
        # --delete is confined to ${PREFIX}; it can never consider another
        # application's keys. index.html is excluded here (and so is exempt from
        # --delete) because it is uploaded last, with different headers.
        # The non-HTML tree is JavaScript only today — add a pass if another
        # asset type ever ships.
        run: |
          set -euo pipefail
          aws s3 sync ./site/ "s3://${BUCKET}/${PREFIX}" \
            --delete \
            --exclude 'index.html' \
            --content-type 'text/javascript; charset=utf-8' \
            --cache-control 'public, max-age=3600'

      - name: Upload index.html last (no-cache)
        id: upload_html
        if: ${{ !inputs.dry_run }}
        # Written last so the entry point never references a bundle that has not
        # landed. Explicit content-type: S3's guessing is not trusted here.
        run: |
          set -euo pipefail
          aws s3 cp ./site/index.html "s3://${BUCKET}/${PREFIX}index.html" \
            --content-type 'text/html; charset=utf-8' \
            --cache-control 'no-cache'

      - name: Invalidate the app prefix and wait
        id: invalidate
        if: ${{ !inputs.dry_run }}
        run: |
          set -euo pipefail
          id=$(aws cloudfront create-invalidation \
                 --distribution-id "${DIST_ID}" \
                 --paths "/${PREFIX}*" \
                 --query 'Invalidation.Id' --output text)
          echo "invalidation=${id}" >> "$GITHUB_OUTPUT"
          echo "created invalidation ${id} for /${PREFIX}*"
          # The healthcheck must not run before propagation finishes, or it
          # would test the old edge copy and trigger a spurious rollback.
          aws cloudfront wait invalidation-completed \
            --distribution-id "${DIST_ID}" --id "${id}"
          echo "invalidation ${id} completed"

      - name: Verify the live site serves this build
        id: verify
        if: ${{ !inputs.dry_run }}
        run: node tools/healthcheck.js "${BASE_URL}" "${BUILD_SHA}"

      - name: Roll back to the previous version
        # Runs only when something after the snapshot failed. Guarded on the
        # snapshot having succeeded — without it there is nothing trustworthy to
        # restore — and on the upload having at least been attempted.
        if: ${{ failure() && !inputs.dry_run && steps.snapshot.outcome == 'success' && steps.upload_assets.outcome != 'skipped' }}
        run: |
          set -euo pipefail
          echo "::error::Deploy verification failed — restoring the previous version."
          # Same two-pass header treatment as a good deploy: a plain sync would
          # let S3 guess content types and lose the cache policy.
          aws s3 sync ./previous/ "s3://${BUCKET}/${PREFIX}" \
            --delete \
            --exclude 'index.html' \
            --content-type 'text/javascript; charset=utf-8' \
            --cache-control 'public, max-age=3600'
          if [ -f ./previous/index.html ]; then
            aws s3 cp ./previous/index.html "s3://${BUCKET}/${PREFIX}index.html" \
              --content-type 'text/html; charset=utf-8' \
              --cache-control 'no-cache'
          fi
          rollback_id=$(aws cloudfront create-invalidation \
                          --distribution-id "${DIST_ID}" \
                          --paths "/${PREFIX}*" \
                          --query 'Invalidation.Id' --output text)
          aws cloudfront wait invalidation-completed \
            --distribution-id "${DIST_ID}" --id "${rollback_id}"
          echo "rolled back; invalidation ${rollback_id} completed"

      - name: Summary
        if: ${{ always() && !inputs.dry_run }}
        run: |
          {
            echo "### Web app deploy"
            echo ""
            echo "| field | value |"
            echo "|---|---|"
            echo "| build | \`${BUILD_SHA}\` |"
            echo "| ref | \`${{ github.ref_name }}\` |"
            echo "| target | \`s3://${BUCKET}/${PREFIX}\` |"
            echo "| url | ${BASE_URL} |"
            echo "| invalidation | \`${{ steps.invalidate.outputs.invalidation || 'n/a' }}\` |"
            echo "| verify | ${{ steps.verify.outcome || 'did not run' }} |"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Validate the YAML parses and the guards are right**

```bash
cd /home/mezinster/nfcarchiver
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.github/workflows/deploy-webapp.yml'))
assert list(d['jobs']) == ['build', 'deploy'], list(d['jobs'])
assert d['permissions'] == {}, d['permissions']
assert d['jobs']['build']['permissions'] == {}
assert d['jobs']['deploy']['permissions']['id-token'] == 'write'
assert d['concurrency']['cancel-in-progress'] is False
assert d['jobs']['deploy']['environment'] == 'production'
assert list(d['on']['workflow_dispatch']['inputs']) == ['dry_run']
steps = d['jobs']['deploy']['steps']
names = [s.get('name') for s in steps]
print('deploy steps:', names)
# index.html must be uploaded after the asset sync
assert names.index('Upload index.html last (no-cache)') > names.index('Upload assets (long-lived cache)')
# rollback must come after verification
assert names.index('Roll back to the previous version') > names.index('Verify the live site serves this build')
print('OK')
PY
```

Expected: prints the step list and `OK`.

- [ ] **Step 3: Confirm no AWS value is hardcoded**

```bash
grep -nE 'arn:aws|[0-9]{12}|E[A-Z0-9]{12,}' .github/workflows/deploy-webapp.yml || echo "clean: no baked-in AWS identifiers"
```

Expected: `clean: no baked-in AWS identifiers`.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/deploy-webapp.yml
git commit -m "feat(ci): manually-triggered S3 + CloudFront deploy for the web app

workflow_dispatch only, with a dry_run input that prints the object-level sync
plan and stops — worth having because --delete points at a bucket shared with
other applications.

Credentials come from GitHub OIDC per run; nothing long-lived is stored. The
build job runs npm ci with permissions: {} and no AWS access, then hands the
deploy job pre-built bytes plus a standalone healthcheck via artifacts, so the
credentialed job never executes third-party code.

Every operation is bound to the app/ prefix: sync, --delete, and the /app/*
invalidation. Before uploading, the live files are snapshotted to the runner;
if invalidation or verification fails, they are restored with their original
headers and re-invalidated, and the run fails.

Verification is a SHA match, not just a 200: proof that CloudFront is serving
this build rather than an edge still holding the previous one."
git push
```

- [ ] **Step 5: First live run — dry run** *(requires the AWS Setup appendix to be complete)*

```bash
gh workflow run deploy-webapp.yml --ref feat/webapp-s3-deploy-pipeline -f dry_run=true
sleep 10 && gh run list --workflow=deploy-webapp.yml --limit 1
```

Then read the `--dryrun` plan:

```bash
gh run view --log --job "$(gh run list --workflow=deploy-webapp.yml --limit 1 --json databaseId --jq '.[0].databaseId')" 2>/dev/null | grep -A20 'would upload\|would delete' || gh run view --log
```

Expected: `(dryrun) upload: ./site/index.html to s3://nfcarchiver.com/app/index.html` and the same for `dist/main.js`. **Any `would delete` line naming a key outside `app/` means stop and re-check `S3_PREFIX`.**

Note: `workflow_dispatch` on a non-default branch requires the workflow file to exist on that branch — it does, after Step 4's push. The `production` environment's deployment-branch rule restricts deploys to `master`, so this dry run will be **rejected at the environment gate** unless the branch is temporarily allowed. Two options: temporarily add `feat/webapp-s3-deploy-pipeline` to the environment's allowed branches for this run, or merge PR #43 first and dry-run from `master`. Prefer merging first — the dry run writes nothing.

- [ ] **Step 6: First live run — real deploy**

```bash
gh workflow run deploy-webapp.yml --ref master
```

Expected: all steps green; the summary table shows the build SHA and `verify: success`. Confirm in a browser that `https://nfcarchiver.com/app/` loads and the About tab shows the matching short SHA.

- [ ] **Step 7: Exercise the rollback path deliberately**

Rollback is otherwise untested code whose first execution would be during an incident. Force verification to fail without shipping anything broken:

Temporarily change the verify step's SHA argument to a value that cannot match, on a scratch branch:

```bash
git checkout -b test/rollback-drill master
sed -i 's|node tools/healthcheck.js "${BASE_URL}" "${BUILD_SHA}"|node tools/healthcheck.js "${BASE_URL}" "0000000"|' .github/workflows/deploy-webapp.yml
git commit -am "test: force healthcheck failure to drill the rollback path"
git push -u origin test/rollback-drill
# allow this branch in the production environment for one run, then:
gh workflow run deploy-webapp.yml --ref test/rollback-drill
```

Expected: upload and invalidation succeed, `Verify` fails, `Roll back to the previous version` runs and completes, and the job ends red. Then confirm the site still serves the **previous** SHA in the About tab.

Clean up:

```bash
git push origin --delete test/rollback-drill
git branch -D test/rollback-drill
# remove the branch from the production environment's allowed list
gh workflow run deploy-webapp.yml --ref master   # restore the intended version
```

---

### Task 5: Documentation and retiring the manual path

**Files:**
- Modify: `webapp/README.md` (new `## Deployment` section before `## Notes & known follow-ups`)
- Modify: `CLAUDE.md` (Web App section)
- Delete: `webapp/s3-upload/` (untracked — `rm -rf`, no commit needed for the deletion itself)

**Interfaces:** none. Documentation only.

- [ ] **Step 1: Add the README section**

Insert into `webapp/README.md` immediately before the `## Notes & known follow-ups` heading:

```markdown
## Deployment

The app is served from `https://nfcarchiver.com/app/` — the `app/` prefix of the
`nfcarchiver.com` S3 bucket, behind CloudFront. The bucket hosts other
applications, so **every deploy operation is confined to that prefix**.

Deploys are manual:

```bash
gh workflow run deploy-webapp.yml --ref master                  # deploy
gh workflow run deploy-webapp.yml --ref master -f dry_run=true  # plan only
```

`dry_run` prints the object-level `aws s3 sync --dryrun` plan and uploads
nothing. Use it whenever the prefix or bucket configuration might have changed.

What the workflow does:

1. **build job** (no AWS access): `npm ci`, full test suite, then
   `npm run build:site`, which stamps the short commit SHA into the bundle via
   esbuild `define` and asserts its own output.
2. **deploy job** (OIDC credential, ~1 h lifetime): snapshots the live files for
   rollback, uploads assets with `max-age=3600` then `index.html` with
   `no-cache`, invalidates `/app/*` and waits for completion, then runs
   `scripts/healthcheck.ts` against the public URL.
3. On verification failure it restores the snapshot with the original headers,
   re-invalidates, and fails the run.

Verification requires the served bundle to contain the SHA that was just built —
a 200 alone would not prove an edge had stopped serving the previous version.
The About tab shows the deployed SHA, so you can confirm what is live by eye.

To build locally without deploying:

```bash
BUILD_SHA=$(git rev-parse --short=7 HEAD) npm run build:site   # -> site/
```

### Configuration

Set once, on the repository. None of these is an AWS credential; the role ARN is
a secret only so the account ID is masked in logs.

| Kind | Name | Value |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | IAM role assumed via OIDC |
| Variable | `AWS_REGION` | bucket region |
| Variable | `S3_BUCKET` | `nfcarchiver.com` |
| Variable | `S3_PREFIX` | `app/` (trailing slash required) |
| Variable | `CLOUDFRONT_DISTRIBUTION_ID` | distribution serving the domain |
| Variable | `SITE_BASE_URL` | `https://nfcarchiver.com/app/` |

There are no long-lived AWS keys anywhere. The `production` GitHub Environment
carries no required reviewers; it exists to pin the OIDC trust policy on
`environment:production` and to restrict deploys to `master`.
```

- [ ] **Step 2: Note the pipeline in CLAUDE.md**

In `CLAUDE.md`, in the `## Web App (webapp/)` bullet list, add after the **Commands** bullet:

```markdown
- **Deploy:** manual only — `gh workflow run deploy-webapp.yml --ref master`
  (add `-f dry_run=true` to print the sync plan without uploading). Builds via
  `npm run build:site`, which stamps the commit SHA into the bundle; the
  post-deploy healthcheck requires the live bundle to carry that SHA, and rolls
  back if it does not. Credentials come from GitHub OIDC — there are no stored
  AWS keys. Every S3 and CloudFront operation is confined to the `app/` prefix
  because the `nfcarchiver.com` bucket hosts other applications. See
  `webapp/README.md` for the configuration table.
```

- [ ] **Step 3: Remove the hand-assembled staging directory**

Superseded by the pipeline. Keeping a stale hand-copied bundle around invites
deploying the wrong bytes:

```bash
cd /home/mezinster/nfcarchiver
rm -rf webapp/s3-upload
git status --short   # should show no trace of it (it was never tracked)
```

- [ ] **Step 4: Confirm the docs match reality**

```bash
cd webapp
grep -n "build:site" package.json README.md ../CLAUDE.md
grep -n "^site/" .gitignore
```

Expected: `build:site` appears in all three files; `site/` is gitignored.

- [ ] **Step 5: Commit**

```bash
cd /home/mezinster/nfcarchiver
git add webapp/README.md CLAUDE.md
git commit -m "docs(webapp): document the deploy pipeline; retire the manual staging dir

README gains a Deployment section (commands, what each job does, the
configuration table) and CLAUDE.md points at it. Removed the untracked
webapp/s3-upload/ hand-assembled bundle now that a reproducible build exists."
git push
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| Two jobs, credentials in one | 4 |
| `dry_run` input | 4 |
| OIDC, no stored keys | 4 + appendix |
| Prefix-bound sync / IAM / invalidation | 4 + appendix |
| Cache headers, explicit content types | 4 |
| Two-pass upload, `index.html` last | 4 |
| Build script (`build:site`), no minification | 1 |
| SHA stamping via `define`, `typeof` guard | 1 |
| Bundle sanity checks | 1 (moved into `build-site.ts` so local builds are checked too, and the workflow gets them free) |
| Healthcheck: 200s, content types, SHA match, backoff | 2 |
| Healthcheck unit tests (3 cases) | 2 (4 cases — added backoff-schedule coverage) |
| Snapshot-based rollback, no bucket versioning | 4 |
| Rollback drill | 4 step 7 |
| `ci.yml` webapp job | 3 |
| `tsconfig` include, gitignore `site/` | 1 |
| Delete `s3-upload/` | 5 |
| README + CLAUDE.md | 5 |
| Config table (secret + 5 variables) | 4 + 5 + appendix |
| AWS operator steps, IAM JSON | appendix |

One intentional deviation from the spec: the bundle sanity checks live in `build-site.ts` rather than as YAML steps in the build job. This is strictly better — the same assertions then guard local builds, and there is one implementation instead of two.

**Placeholder scan:** none. Every code step contains the full file or the exact replacement lines. `AWS_ACCOUNT_ID` / `DISTRIBUTION_ID` in the appendix JSON are operator substitutions, flagged as such at the point of use.

**Type consistency:** `BUILD_SHA` (Task 1 export) is read as `BUILD_SHA` env var in Task 4 and as `process.env.BUILD_SHA` in Task 1's script. `checkOnce` / `healthcheck` / `CheckResult` / `HealthcheckOptions` signatures in Task 2's implementation match their use in Task 2's test. `steps.snapshot` / `steps.upload_assets` / `steps.invalidate` / `steps.verify` ids in Task 4 all exist on the steps they reference.

---

## Appendix: AWS Setup (operator steps)

Do these before Task 4 Step 5. Nothing in Tasks 1–3 depends on them.

### 1. Register GitHub as an OIDC identity provider

IAM → **Identity providers** → **Add provider** → **OpenID Connect**

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

Click **Get thumbprint**, then **Add provider**. If a provider for this URL already exists, skip — there can only be one per account.

### 2. Create the deploy role

IAM → **Roles** → **Create role** → **Custom trust policy**. Paste this, replacing `AWS_ACCOUNT_ID` with your 12-digit account ID:

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

Name it `nfcarchiver-webapp-deploy`.

**The `sub` condition is the entire security boundary.** It must be `StringEquals` on that exact string. A wildcard, or switching to `StringLike` with a `*`, would let other repositories assume this role.

### 3. Attach the permission policy

On the new role → **Add permissions** → **Create inline policy** → JSON. Replace `AWS_ACCOUNT_ID` and `DISTRIBUTION_ID`:

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

Name it `nfcarchiver-webapp-deploy-policy`.

This role cannot touch another application's prefix even if the workflow asked it to. That is deliberate: correct paths in the workflow, plus a policy under which a wrong path fails.

### 4. Check two bucket facts

Both can change the policy above:

**a. Object ACLs.** S3 → bucket `nfcarchiver.com` → **Permissions** → **Object Ownership**.
- *ACLs disabled* (modern default; objects served via a bucket policy with Origin Access Control) → the policy above is complete.
- *ACLs enabled* and objects served public-read → add `"s3:PutObjectAcl"` to the `AppPrefixObjects` action list, and tell me, because the workflow's two upload steps then need `--acl public-read`.

**b. How `/app/` resolves to `/app/index.html`.** CloudFront → the distribution → **Behaviors**, and **Functions** / **Origins**. Report which mechanism is in play:
- CloudFront `Default root object` (only covers `/`, not `/app/`)
- A CloudFront Function or Lambda@Edge rewriting directory URIs
- An S3 *static website* origin (the website endpoint applies index documents per directory)

It works today, so this is a sanity check — but if a Function performs the rewrite, we need to know it is not affected by re-uploading `index.html`.

### 5. Collect these values

- Role ARN: `arn:aws:iam::<account>:role/nfcarchiver-webapp-deploy`
- Bucket region (S3 → bucket → **Properties** → AWS Region), e.g. `eu-central-1`
- CloudFront distribution ID (the `E…` string)
- Answers to 4a and 4b

### 6. Configure GitHub

Repository → **Settings**.

**Environments** → **New environment** → `production`:
- Required reviewers: **leave empty**
- Deployment branches and tags: **Selected branches** → add rule `master`

**Secrets and variables → Actions**:

| Tab | Name | Value |
|---|---|---|
| Secrets | `AWS_DEPLOY_ROLE_ARN` | the role ARN from step 5 |
| Variables | `AWS_REGION` | bucket region |
| Variables | `S3_BUCKET` | `nfcarchiver.com` |
| Variables | `S3_PREFIX` | `app/` — **trailing slash required** |
| Variables | `CLOUDFRONT_DISTRIBUTION_ID` | the `E…` id |
| Variables | `SITE_BASE_URL` | `https://nfcarchiver.com/app/` |

`S3_PREFIX` without its trailing slash would make the workflow target `s3://nfcarchiver.com/appindex.html`. The dry run in Task 4 Step 5 catches this, which is why it goes first.
