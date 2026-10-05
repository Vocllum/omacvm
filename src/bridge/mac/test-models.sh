#!/bin/bash
# Offline tests of the Bridge's rules without AppKit: when the media-key tap
# is created again (keys-model.swift). No permissions.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/models-test" "$HERE/keys-model.swift" "$HERE/tests/models/main.swift"
"$T/models-test"
