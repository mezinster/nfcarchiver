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
