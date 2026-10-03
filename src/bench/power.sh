#!/bin/bash
# The Mac's average power draw over a time window, from the battery's own
# telemetry (no sudo): AccumulatedSystemLoad / SystemLoadAccumulatorCount in
# AppleSmartBattery. Counts the whole Mac (display included), on battery or
# on the charger. macOS updates these about every 45 s, in batches, so the
# window starts and ends on an update: it lasts SECONDS plus up to a minute.
#   power.sh SECONDS [LABEL]   -> {"label", "seconds", "watts"} as one JSON line
set -euo pipefail
secs=${1:?usage: power.sh SECONDS [LABEL]}; label=${2:-}
read_acc() {   # -> "accumulated_mW count"
  ioreg -rw0 -c AppleSmartBattery | tr ',{}' '\n\n\n' |
    sed -n 's/^"AccumulatedSystemLoad"=\([0-9]*\)$/a \1/p; s/^"SystemLoadAccumulatorCount"=\([0-9]*\)$/n \1/p' |
    sort | awk '{ v[$1] = $2 } END { print v["a"], v["n"] }'
}
next_update() {   # waits for the next batch, then prints it
  local a n a2 n2
  read -r a n <<<"$(read_acc)"
  for _ in $(seq 120); do
    sleep 1; read -r a2 n2 <<<"$(read_acc)"
    [[ $n2 != "$n" ]] && { echo "$a2 $n2"; return 0; }
  done
  echo "power.sh: no telemetry updates (is this a MacBook?)" >&2; return 1
}
read -r a0 n0 <<<"$(next_update)"; t0=$SECONDS
sleep "$secs"
read -r a1 n1 <<<"$(next_update)"; t1=$SECONDS
awk -v a="$((a1 - a0))" -v n="$((n1 - n0))" -v s="$((t1 - t0))" -v l="$label" \
  'BEGIN { printf "{\"label\": \"%s\", \"seconds\": %d, \"watts\": %.2f}\n", l, s, a / n / 1000 }'
