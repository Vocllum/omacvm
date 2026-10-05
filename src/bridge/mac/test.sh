#!/bin/bash
# Offline tests of the Bridge's external display brightness (steps, DDC/CI
# packets, which display a VM is on): no display, no permissions.
#   test.sh          the offline tests (CI)
#   test.sh --live   also on this Mac's external displays, through the
#                    Bridge's own code: reads each one, sets the first that
#                    works a few points brighter, reads it back and ALWAYS
#                    sets the value it had again (also on errors and Ctrl-C).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/external-test" "$HERE/external-model.swift" "$HERE/tests/offline/main.swift"
"$T/external-test"
[[ ${1:-} == --live ]] || exit 0

swiftc -O -swift-version 5 -o "$T/external-live" "$HERE/external-model.swift" "$HERE/external-brightness.swift" \
  "$HERE/tests/live/main.swift" -framework AppKit -framework IOKit
L=$T/external-live
echo "external displays:"; "$L" report
id=$("$L" report | jq -r '[.[] | select(.method != "none")][0].id // empty')
[[ -n $id ]] || { echo "no external display takes brightness here: nothing to set"; exit 0; }
before=$("$L" get "$id" | jq -r .brightness)
echo "display $id: $before % before"
trap '"$L" set "$id" "$before" >/dev/null && echo "display $id: back to $before % ($("$L" get "$id" | jq -r .brightness) % read back)"; rm -rf "$T"' EXIT
trap 'exit 130' INT TERM
to=$(( before <= 90 ? before + 6 : before - 6 ))
"$L" set "$id" "$to" >/dev/null
sleep 1
now=$("$L" get "$id" | jq -r .brightness)
echo "display $id: set $to %, read back $now %"
(( now == to )) || { echo "FAIL: read back $now, wanted $to"; exit 1; }
# Brightness keys held: 4 steps up, 4 down, at key-repeat speed (coalesced writes):
# back on macOS's step grid at the level it started from.
"$L" keys "$id" 4
grid=$(( (to * 16 + 50) / 100 )); want=$(( (grid * 100 + 8) / 16 ))
now=$("$L" get "$id" | jq -r .brightness)
echo "display $id: 4 up, 4 down from $to %: $now % (want $want %)"
(( now == want )) || { echo "FAIL: keys ended at $now, wanted $want"; exit 1; }
echo "live: ok"
