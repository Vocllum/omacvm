#!/bin/bash
# The update feed for a release (docs/adr/0033): dist/OmacVM-appcast.json
# and its Ed25519 signature dist/OmacVM-appcast.json.sig, for the zip that
# package-release.sh made. Upload both to the GitHub release v<version> with
# the zip; installed apps find them through releases/latest.
#   scripts/appcast.sh      (package-release.sh runs it)
# The release key's private half comes from the Keychain (generic password,
# service org.omacvm.release-key) or OMACVM_RELEASE_KEY_FILE; its public half
# is src/lib/release-key.pub, which every app carries. Without that file no
# feed is made: updates start with the first release that has a key.
# New key (once): swift src/release/sign.swift keygen KEYFILE > src/lib/release-key.pub
#   security add-generic-password -s org.omacvm.release-key -a omacvm -w "$(cat KEYFILE)"
#   then keep KEYFILE offline (a backup) and delete it here.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION=$(cat "$REPO/src/VERSION")
ZIP=$ROOT/dist/OmacVM-$VERSION.zip
FEED=$ROOT/dist/OmacVM-appcast.json
PUB=$REPO/src/lib/release-key.pub
SIGN=$REPO/src/release/sign.swift
[[ -f $PUB ]] || die "no src/lib/release-key.pub yet: no update feed (installed apps check nothing until a release has a key)"
[[ -f $ZIP ]] || die "no $ZIP: run scripts/package-release.sh first"
[[ $VERSION =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || die "src/VERSION ($VERSION) is not a release version"

# The zip's app is the one the feed promises: version, bundle id, Developer ID.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ditto -x -k "$ZIP" "$tmp"
APP=$tmp/OmacVM.app
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] || die "the zip's app is not $VERSION"
[[ $(plist CFBundleIdentifier) == org.omacvm.app ]] || die "the zip's app is not org.omacvm.app"
DEVID='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'
codesign --verify --deep --strict -R="$DEVID" "$APP" 2>/dev/null || die "the zip's app is not signed with OmacVM's Developer ID"
MIN=$(plist LSMinimumSystemVersion)

URL=https://github.com/gillesgoetsch/omacvm/releases/download/v$VERSION/OmacVM-$VERSION.zip
LENGTH=$(stat -f %z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
cat > "$FEED" <<EOF
{
  "schema": 1,
  "version": "$VERSION",
  "url": "$URL",
  "length": $LENGTH,
  "sha256": "$SHA",
  "minimum_macos": "$MIN",
  "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v$VERSION",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

if [[ -n ${OMACVM_RELEASE_KEY_FILE:-} ]]; then
  swift "$SIGN" sign "$OMACVM_RELEASE_KEY_FILE" "$FEED" > "$FEED.sig"
else
  security find-generic-password -s org.omacvm.release-key -w 2>/dev/null | swift "$SIGN" sign - "$FEED" > "$FEED.sig" ||
    die "no release key: Keychain item org.omacvm.release-key, or OMACVM_RELEASE_KEY_FILE"
fi
# Signed with the key the apps know, or nothing goes out.
swift "$SIGN" verify "$(cat "$PUB")" "$FEED" "$FEED.sig" >/dev/null ||
  { rm -f "$FEED" "$FEED.sig"; die "the signature does not match src/lib/release-key.pub: wrong key"; }
printf '==> %s\n==> %s\n' "$FEED" "$FEED.sig"
