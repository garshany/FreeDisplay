#!/usr/bin/env bash
# Prepare locally only. Owner supplies a fork key/account and Sparkle tools; never publishes.
# Usage: SPARKLE_BIN=… SPARKLE_KEYCHAIN_ACCOUNT=… SPARKLE_MAXIMUM_DELTAS=… \
#        scripts/prepare-appcast.sh archive.zip vVERSION output/appcast.xml [notes.md]
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="${1:?Pass the final signed, stapled archive}"
TAG="${2:?Pass the release tag}"
OUTPUT="${3:?Pass the output appcast path}"
NOTES="${4:-}"
: "${SPARKLE_BIN:?Pass the resolved Sparkle bin directory}"
: "${SPARKLE_KEYCHAIN_ACCOUNT:?Pass the FreeDisplay-owned keychain account}"
: "${SPARKLE_MAXIMUM_DELTAS:?Owner must supply the delta-generation policy}"
for tool in generate_appcast generate_keys sign_update; do
  [ -x "$SPARKLE_BIN/$tool" ] || { echo "error: missing $SPARKLE_BIN/$tool" >&2; exit 1; }
done
[ -f "$ARCHIVE" ] || { echo "error: missing archive: $ARCHIVE" >&2; exit 1; }
PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p)
python3 scripts/validate-appcast.py --archive "$ARCHIVE" --public-key "$PUBLIC_KEY"
mkdir -p "$(dirname "$OUTPUT")"
STAGE=$(mktemp -d "$(dirname "$OUTPUT")/freedisplay-appcast.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/$(basename "$ARCHIVE")"
if [ -n "$NOTES" ]; then
  cp "$NOTES" "$STAGE/$(basename "${ARCHIVE%.*}").md"
fi
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
  --maximum-versions 0 --maximum-deltas "$SPARKLE_MAXIMUM_DELTAS" \
  --download-url-prefix "https://github.com/garshany/FreeDisplay/releases/download/$TAG/" \
  --link "https://github.com/garshany/FreeDisplay" --embed-release-notes \
  -o "$STAGE/appcast.xml" "$STAGE"
python3 scripts/validate-appcast.py --archive "$ARCHIVE" --public-key "$PUBLIC_KEY" \
  --appcast "$STAGE/appcast.xml" --tag "$TAG"
SIGNATURE=$(python3 scripts/validate-appcast.py --archive "$ARCHIVE" --public-key "$PUBLIC_KEY" \
  --appcast "$STAGE/appcast.xml" --tag "$TAG" --print-signature)
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEYCHAIN_ACCOUNT" --verify "$ARCHIVE" "$SIGNATURE"
mv "$STAGE/appcast.xml" "$OUTPUT"
echo "FreeDisplay appcast prepared locally: $OUTPUT (nothing published)"
