#!/bin/bash
# Runs every harness for SECONDS (default 300) from seeds/ into corpus/
# (not in git), then the regression inputs. Crashes land in crashes/.
#   tests/fuzz/build.sh && tests/fuzz/run.sh 600
set -euo pipefail
cd "$(dirname "$0")"
secs=${1:-300}
mkdir -p corpus crashes
run() {
  local t=$1; shift
  mkdir -p "corpus/$t"; cp -n seeds/"$t"/* "corpus/$t/" 2>/dev/null || true
  "out/$t" -max_total_time="$secs" -rss_limit_mb=1024 -artifact_prefix="crashes/${t}_" "$@" "corpus/$t" \
    > "out/$t.log" 2>&1 &
}
run omanotch_stream -max_len=4096
run gestures -max_len=1400 -dict=gestures.dict -close_fd_mask=1
run bridge_http -max_len=16384
run camera_requests -max_len=10000
run battery_lines -max_len=20000
wait || true
# Lines that are not JSON used to leave an autoreleased NSError each on a
# thread that never drains its pool: memory grew without end (over 1 GB after 400k runs, ~430 MB fixed).
# The camera port had the same growth.
for t in battery_lines camera_requests; do
  mkdir -p "out/regression-$t"
  "out/$t" -runs=400000 -rss_limit_mb=768 -max_len=64 "out/regression-$t" "regressions/$t" > "out/regression-$t.log" 2>&1
done
grep -h 'SUMMARY\|DONE\|^Done' out/*.log
ls crashes
