/**
 * Post-deploy verification. Fetches the live site through its PUBLIC url — so
 * DNS, CloudFront and S3 are all exercised, not just the origin — and asserts
 * it is serving the bundle this run built.
 *
 *   node dist/scripts/healthcheck.js https://nfcarchiver.com/app/ <sha>
 *
 * A 200 only proves S3 holds something. The SHA match is the load-bearing
 * check: it proves the bundle is THIS build and that no edge is still serving
 * the previous one. That matters doubly with an S3 static-website origin, which
 * answers a missing key with the bucket's error document rather than nothing —
 * so both the content-type check and the SHA check guard against HTML being
 * served where JavaScript belongs.
 */
import { pathToFileURL } from 'node:url';
import { buildMarker } from './build-marker.js';

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
    // Match the prefixed sentinel, never the bare SHA — see build-marker.ts for
    // why a 7-hex-character needle can match an unrelated constant.
    const marker = buildMarker(expectedSha);
    if (!body.includes(marker)) {
      failures.push(`served bundle does not carry the build marker ${marker} — an older version is still live`);
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
