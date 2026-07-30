/**
 * The single definition of the build sentinel, shared by the writer
 * (build-site.ts) and the reader (healthcheck.ts) so the two cannot drift.
 *
 * Why a prefixed sentinel rather than searching the bundle for the bare SHA:
 * the bundle is full of hex string constants (CRC tables, APDU literals such as
 * "C82000000000"), so a 7-hex-character needle can match by pure coincidence. A
 * SHA of 0000000 really does appear in an unrelated constant. A false match
 * means the healthcheck passes a stale deploy — the exact failure it exists to
 * catch — so the needle must be something that cannot occur by accident.
 */
export function buildMarker(sha: string): string {
  return `nfar-build:${sha}`;
}
