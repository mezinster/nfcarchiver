#!/usr/bin/env bash
# Publishes an Apple Alternative Distribution Package (ADP) and the AltStore PAL
# source to https://nfcarchiver.com/altstore/. See altstore/README.md.
#
#   altstore/publish.sh <extracted-adp-dir> [--dry-run]
#
# Needs an AWS CLI session that may write the site bucket (`aws login`), jq,
# curl and sha256sum. The ADP files are copied byte for byte: never edit,
# reformat, re-zip or rename them; the package signature covers them.
set -euo pipefail

BUCKET=nfcarchiver.com
SITE=https://nfcarchiver.com
HERE=$(cd "$(dirname "$0")" && pwd)

ADP=${1:?usage: publish.sh <extracted-adp-dir> [--dry-run]}
DRY=${2:-}
[[ -f $ADP/manifest.json && -f $ADP/signature && -d $ADP/variant ]] \
  || { echo "not an extracted ADP: $ADP" >&2; exit 1; }

VERSION=$(jq -r .shortVersionString "$ADP/manifest.json")
BUILD=$(jq -r .bundleVersion "$ADP/manifest.json")
PREFIX=altstore/releases/$VERSION

# 1. The source must describe this package.
jq -e --arg v "$VERSION" --arg b "$BUILD" --slurpfile m "$ADP/manifest.json" '
  .apps[] | select(.bundleIdentifier == $m[0].bundleId)
  | .marketplaceID == $m[0].appleItemId
    and any(.versions[]; .version == $v and .buildVersion == $b
      and (.downloadURL | endswith("/releases/\($v)/manifest.json")))
' "$HERE/source.json" >/dev/null \
  || { echo "source.json has no version $VERSION ($BUILD) matching the manifest" >&2; exit 1; }

# 2. Every variant must match the manifest (single-chunk sha256 + size), and
#    the variant folder must hold nothing else.
want=$(jq -r '.variants | length' "$ADP/manifest.json")
have=$(find "$ADP/variant" -type f | wc -l)
[[ $want == "$have" ]] || { echo "manifest lists $want variants, folder has $have" >&2; exit 1; }
while IFS=$'\t' read -r path size digest chunks; do
  [[ $chunks == 1 ]] || { echo "$path: $chunks chunks, expected 1" >&2; exit 1; }
  [[ $(stat -c%s "$ADP/$path") == "$size" ]] || { echo "$path: size mismatch" >&2; exit 1; }
  [[ $(sha256sum "$ADP/$path" | cut -d' ' -f1) == "$digest" ]] || { echo "$path: sha256 mismatch" >&2; exit 1; }
done < <(jq -r '.variants[] | [.assetPath, .variantDetails.compressedSize,
  .variantDetails.hashes[0].encryptedChunkDigests[0],
  (.variantDetails.hashes[0].encryptedChunkDigests | length)] | @tsv' "$ADP/manifest.json")
echo "ADP $VERSION ($BUILD): $want variants match the manifest"

# Local checksums of everything that goes out, relative to the ADP root.
SUMS=$(mktemp); trap 'rm -f "$SUMS"' EXIT
(cd "$ADP" && find . -type f -printf '%P\n' | sort | xargs -d '\n' sha256sum) > "$SUMS"
cat "$SUMS"

[[ $DRY == --dry-run ]] && { echo "dry run: nothing uploaded"; exit 0; }

# 3. A published release is immutable: a changed file under the same URL
#    would no longer match what devices may have cached.
if aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/" --max-items 1 \
     --query 'Contents[0].Key' --output text | grep -qv '^None$'; then
  echo "s3://$BUCKET/$PREFIX/ already exists; publish a new version instead" >&2
  exit 1
fi

put() { # <local> <key> <content-type> <cache-control>
  aws s3 cp "$1" "s3://$BUCKET/$2" --only-show-errors \
    --content-type "$3" --cache-control "$4" --checksum-algorithm SHA256
}

# 4. The package. Release files never change, so they cache for a year.
IMMUTABLE='public, max-age=31536000, immutable'
put "$ADP/manifest.json" "$PREFIX/manifest.json" application/json "$IMMUTABLE"
put "$ADP/signature" "$PREFIX/signature" application/octet-stream "$IMMUTABLE"
for f in "$ADP"/variant/*; do
  put "$f" "$PREFIX/variant/$(basename "$f")" application/octet-stream "$IMMUTABLE"
done

# 5. Icon, screenshots, then the source last, so it never points at a
#    package that isn't there yet.
put "$HERE/icon.png" altstore/icon.png image/png 'public, max-age=86400'
for f in "$HERE"/screenshots/*.png; do
  put "$f" "altstore/screenshots/$(basename "$f")" image/png 'public, max-age=86400'
done
put "$HERE/source.json" altstore/source.json application/json 'public, max-age=300'

# 6. Drop cached copies of the mutable files (the id stays out of the log).
DIST=$(aws cloudfront list-distributions --output text \
  --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '$BUCKET')].Id | [0]")
INV=$(aws cloudfront create-invalidation --distribution-id "$DIST" \
  --paths '/altstore/source.json' '/altstore/icon.png' '/altstore/screenshots/*' \
  --query 'Invalidation.Id' --output text)
echo "waiting for the CloudFront invalidation"
aws cloudfront wait invalidation-completed --distribution-id "$DIST" --id "$INV"

# 7. What the public gets must be byte-identical: plain GET, no redirects
#    followed, no compression requested.
bad=0
while read -r sum rel; do
  url=$SITE/$PREFIX/$rel
  got=$(curl -sS --fail --max-redirs 0 -A 'nfcarchiver-publish' "$url" | sha256sum | cut -d' ' -f1) || got=fetch-failed
  if [[ $got == "$sum" ]]; then echo "ok   $url"; else echo "BAD  $url ($got)"; bad=1; fi
done < "$SUMS"
for rel in source.json icon.png $(cd "$HERE" && ls screenshots/*.png); do
  got=$(curl -sS --fail --max-redirs 0 -A 'nfcarchiver-publish' "$SITE/altstore/$rel" | sha256sum | cut -d' ' -f1) || got=fetch-failed
  if [[ $got == $(sha256sum "$HERE/$rel" | cut -d' ' -f1) ]]; then echo "ok   $SITE/altstore/$rel"; else echo "BAD  $SITE/altstore/$rel"; bad=1; fi
done
exit $bad
