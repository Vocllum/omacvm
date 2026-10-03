#!/bin/bash
# Zip dist/OmacVM.app for a GitHub release: dist/OmacVM-<version>.zip and its
# .sha256, the version from src/VERSION. Upload both to the release v<version>;
# omacvm build --vm-type app and omacvm update download them from there.
#   scripts/package-release.sh   (after scripts/build-app.sh --release)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION=$(cat "$REPO/src/VERSION")
APP=$ROOT/dist/OmacVM.app
ZIP=$ROOT/dist/OmacVM-$VERSION.zip
[[ -d $APP ]] || die "no $APP: run scripts/build-app.sh --release first"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] ||
  die "the app is $(plist CFBundleShortVersionString), src/VERSION says $VERSION: build it again"
[[ $(plist OmacVMCommit) == "$(git -C "$REPO" rev-parse HEAD)" ]] ||
  die "the app was built from another commit: build it again (scripts/build-app.sh --release)"
[[ -z $(git -C "$REPO" status --porcelain) ]] || die "uncommitted changes: a release comes from a clean tree"
# Releases are signed with OmacVM's Developer ID (team 722686Y34B), as
# omacvm build --vm-type app and omacvm update check: no ad hoc build.
TEAM=722686Y34B
DEVID="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""
codesign --verify --deep --strict "$APP" || die "the app's signature does not verify"
codesign --verify -R="$DEVID" "$APP" 2>/dev/null ||
  die "the app is not signed with the Developer ID of team $TEAM: build it with OMACVM_SIGN_ID"

rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
printf '==> %s (%s)\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)"
printf '==> %s\n' "$ZIP.sha256"
