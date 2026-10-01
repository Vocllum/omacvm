#!/bin/bash
# Sign an Omaparallels Mac app so macOS remembers its permissions across
# rebuilds and updates: lib/sign.sh <bundle> <identifier>
# Ad-hoc signatures are normally pinned to the binary's hash, so every rebuild
# looked like a new app to Location Services / Accessibility / Input
# Monitoring. The designated requirement here names the bundle identifier
# instead. SIGN_IDENTITY="Developer ID Application: ..." signs with a real
# certificate (Apple's usual team-based requirement then applies).
set -euo pipefail
B=${1:?usage: sign.sh <bundle> <identifier>}; ID=${2:?identifier}
if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$ID" "$B"
else
  codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$B"
fi
codesign --verify --strict "$B"
