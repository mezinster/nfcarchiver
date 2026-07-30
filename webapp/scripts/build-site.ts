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
