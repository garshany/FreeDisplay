#!/usr/bin/env bash
# Local build/package only. GitHub Actions owns publishing; no account, key or notary required.
# Usage: BUILD_NUMBER=123 scripts/release-adhoc.sh [derived-data-path] [artifact-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${1:-$PWD/.dd/release}"
DIST="${2:-$PWD/.dd/artifacts}"
case "$DD" in /*) ;; *) DD="$PWD/$DD" ;; esac
case "$DIST" in /*) ;; *) DIST="$PWD/$DIST" ;; esac
OVERRIDES=(CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
if [ -n "${BUILD_NUMBER:-}" ]; then
  OVERRIDES+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi
PROJECT_SPEC=project.yml ./scripts/bundle-helper.sh Release "$DD" "${OVERRIDES[@]}"
APP="$DD/Build/Products/Release/FreeDisplay.app"
PLIST="$APP/Contents/Info.plist"
# Releases are metadata-only, never Sparkle installs. Local/source builds retain their true flag.
/usr/libexec/PlistBuddy -c 'Set :OpenDisplayLocalBuild false' "$PLIST"
# Keep the update key empty even if local environment overrides were present.
python3 - "$PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info["SUPublicEDKey"] = ""
path.write_bytes(plistlib.dumps(info))
PY
if [ -n "${RELEASE_TAG:-}" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
  [ "$RELEASE_TAG" = "v$VERSION" ] || { echo "error: release tag differs from built version" >&2; exit 1; }
fi

sign() { codesign --force --sign - --timestamp=none "$@"; }
# Sign nested Sparkle code even though its updater is disabled: the outer seal covers every helper.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for version_dir in "$SPARKLE"/Versions/*; do
    [ -L "$version_dir" ] && continue
    for nested in "$version_dir"/XPCServices/*.xpc "$version_dir"/Autoupdate "$version_dir"/Updater.app; do
      [ -e "$nested" ] || continue
      sign "$nested"
    done
  done
fi
for framework in "$APP"/Contents/Frameworks/*.framework; do
  sign "$framework"
done
sign --identifier io.github.garshany.FreeDisplay.opendisplay "$APP/Contents/Helpers/opendisplay"
sign --entitlements Apps/OpenDisplay/Resources/OpenDisplay.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DIST"
# The standalone CLI needs its dynamic frameworks beside it; a bare binary cannot run on a clean Mac.
CLI_STAGE=$(mktemp -d "$DD/cli-package.XXXXXX")
trap 'rm -rf "$CLI_STAGE"' EXIT
mkdir -p "$CLI_STAGE/opendisplay"
cp "$APP/Contents/Helpers/opendisplay" "$CLI_STAGE/opendisplay/opendisplay"
for name in DisplayDomain ProviderInterfaces SceneEngine AutomationSchema TopologyCore CoreGraphicsProvider ExperimentalLifecycleProvider; do
  ditto "$APP/Contents/Frameworks/$name.framework" "$CLI_STAGE/opendisplay/$name.framework"
  codesign --verify --strict "$CLI_STAGE/opendisplay/$name.framework"
done
codesign --verify --strict "$CLI_STAGE/opendisplay/opendisplay"
# Remove previous archives before ditto, which otherwise updates an existing zip in place.
rm -f "$DIST/FreeDisplay.zip" "$DIST/opendisplay.zip"
ditto -c -k --keepParent "$APP" "$DIST/FreeDisplay.zip"
ditto -c -k --keepParent "$CLI_STAGE/opendisplay" "$DIST/opendisplay.zip"
(cd "$DIST" && shasum -a 256 FreeDisplay.zip > FreeDisplay.zip.sha256 && shasum -a 256 opendisplay.zip > opendisplay.zip.sha256)
(cd "$DIST" && shasum -a 256 -c FreeDisplay.zip.sha256 && shasum -a 256 -c opendisplay.zip.sha256)
echo "Prepared ad-hoc archives and SHA-256 files in $DIST; nothing published."
