#!/bin/bash
# webgl.sh [--version 1.0.4|2.0.0] [--filter REGEX] [--minutes N] [--out FILE.json]
# Khronos WebGL conformance (conformance-suites/2.0.0) in Chrome inside the guest's Hyprland
# session (real GPU path, unattended), results as JSON. VM must be up (vm.sh start).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
VERSION=1.0.4; FILTER=.; MIN=30; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --version) VERSION=$2; shift 2;; --filter) FILTER=$2; shift 2;;
  --minutes) MIN=$2; shift 2;; --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
OUT=${OUT:-$H/results/webgl-$VERSION-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
V="$H/vm.sh"; G=/opt/webgl-cts
WV=1; [[ $VERSION == 2* ]] && WV=2
"$V" ssh "mkdir -p $G; [ -d $G/src ] || (git clone -q --depth 1 --filter=blob:none --sparse https://github.com/KhronosGroup/WebGL $G/src && git -C $G/src sparse-checkout set conformance-suites/2.0.0); git -C $G/src rev-parse HEAD > $G/commit"
"$V" ssh "cat > $G/server.py" < "$H/guest/webgl-server.py"
"$V" ssh "cat > $G/runner.html" < "$H/guest/webgl-runner.html"
"$V" ssh "pkill -f '$G/[s]erver.py'" || true
"$V" ssh "rm -f $G/out.jsonl; nohup python3 $G/server.py $G/src/conformance-suites/2.0.0 $G/runner.html $G/out.jsonl $VERSION '$FILTER' 8765 >/dev/null 2>&1 &"
sleep 1
chrome() {  # chrome START_PAGE
  "$V" session bash -c "nohup google-chrome-stable --user-data-dir=/tmp/webgl-prof --no-first-run --no-default-browser-check --ozone-platform=wayland --disable-background-timer-throttling --disable-renderer-backgrounding 'http://127.0.0.1:8765/omacvm-runner.html?v=$WV&start=$1' >>/tmp/webgl-chrome.log 2>&1 &"
}
"$V" ssh "rm -rf /tmp/webgl-prof /tmp/webgl-chrome.log"
chrome 0
# A page can block the renderer in a GL call (the runner's own timeout never fires then).
# No new result for STALL seconds: record the page as "hang", restart Chrome at the next page.
STALL=${STALL:-300}; end=$(( $(date +%s) + MIN*60 )); status=complete; last=-1; since=$(date +%s); hangs=0
while :; do
  n=$("$V" ssh -o ConnectTimeout=20 "grep -q '\"kind\": \"done\"' $G/out.jsonl && echo done || { grep -c '\"kind\": \"result\"' $G/out.jsonl || true; }" 2>/dev/null || true)
  [ "$n" = done ] && break
  now=$(date +%s)
  [ "$now" -ge $end ] && { status=time-limit; break; }
  # paused by another track's benchmark (kill -STOP): the time limit and the stall clock wait
  if [[ $(ps -o stat= -p "$("$V" pid)") == T* ]]; then end=$((end + 10)); since=$now; sleep 10; continue; fi
  if [ -n "$n" ] && [ "$n" != "$last" ]; then last=$n; since=$now; fi
  if [ -n "$n" ] && [ $((now - since)) -ge $STALL ]; then
    hangs=$((hangs + 1))
    "$V" ssh "pkill -9 -f '/tmp/[w]ebgl-prof'; sleep 2; curl -s http://127.0.0.1:8765/list.json | python3 -c 'import json,sys; t=json.load(sys.stdin)[$n]; print(json.dumps({\"test\": t, \"status\": \"hang\", \"pass\": 0, \"fail\": 1, \"skip\": 0, \"ms\": $STALL * 1000, \"msgs\": [\"no result for $STALL s, Chrome restarted\"]}))' | curl -s -X POST --data-binary @- http://127.0.0.1:8765/result"
    echo "page $n hung for $STALL s, Chrome restarted at page $((n + 1))"
    "$V" ssh "dmesg | tail -20" > "$OUT.hang-$hangs.dmesg" 2>/dev/null
    chrome $((n + 1)); since=$(date +%s)
  fi
  sleep 10
done
"$V" ssh "pkill -f '/tmp/[w]ebgl-prof'; pkill -f '$G/[s]erver.py'; cat $G/commit" > "$OUT.commit" || true
"$V" ssh "cat $G/out.jsonl" > "$OUT.jsonl"
python3 - "$OUT.jsonl" "$OUT" "$VERSION" "$FILTER" "$status" "$(cat "$OUT.commit")" <<'PY'
import json, sys
src, out, version, filt, status, commit = sys.argv[1:7]
recs = [json.loads(l) for l in open(src) if l.strip()]
start = next((r for r in recs if r["kind"] == "start"), {})
res = [r for r in recs if r["kind"] == "result"]
count = {k: sum(1 for r in res if r["status"] == k) for k in ("pass", "fail", "timeout", "hang")}
sub = {k: sum(r[k] for r in res) for k in ("pass", "fail", "skip")}
summary = {"suite": "webgl-conformance", "suite_version": "conformance-suites/2.0.0", "webgl": version,
           "khronos_webgl_commit": commit, "filter": filt, "run": status,
           "renderer": start.get("renderer"), "user_agent": start.get("userAgent"),
           "pages_listed": start.get("count"), "pages_run": len(res), "pages": count,
           "page_pass_rate": round(count["pass"] / len(res), 4) if res else None,
           "subtests": sub,
           "subtest_pass_rate": round(sub["pass"] / (sub["pass"] + sub["fail"]), 4) if sub["pass"] + sub["fail"] else None,
           "failed_pages": [{"test": r["test"], "status": r["status"], "fail": r["fail"], "msgs": r["msgs"][:3]}
                            for r in res if r["status"] != "pass"]}
json.dump(summary, open(out, "w"), indent=1)
print(json.dumps({k: summary[k] for k in ("webgl", "run", "renderer", "pages_run", "pages", "subtests", "subtest_pass_rate")}))
PY
