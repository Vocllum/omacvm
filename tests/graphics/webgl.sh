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
"$V" ssh "cat > $G/driver.py" < "$H/guest/webgl-driver.py"
"$V" ssh "pkill -f '$G/[d]river.py'; pkill -9 -f '/tmp/[w]ebgl-prof'; rm -rf /tmp/webgl-prof /tmp/webgl-chrome.log" || true
# the driver (guest) restarts Chrome after failing or hung pages; ISOLATE=0 runs all pages in one Chrome
"$V" session bash -c "nohup python3 $G/driver.py $G/out.jsonl $WV ${ISOLATE:-1} ${STALL:-300} > /tmp/webgl-driver.log 2>&1 &"
end=$(( $(date +%s) + MIN*60 )); status=complete
while ! "$V" ssh -o ConnectTimeout=20 "grep -q '\"kind\": \"done\"' $G/out.jsonl" 2>/dev/null; do
  qp=$("$V" pid); [ -z "$qp" ] && { status=qemu-exited; break; }
  [ "$(date +%s)" -ge $end ] && { status=time-limit; break; }
  # paused by another track's benchmark (kill -STOP): the time limit waits too
  [[ $(ps -o stat= -p "$qp") == T* ]] && end=$((end + 10))
  sleep 10
done
"$V" ssh "pkill -f '$G/[d]river.py'" || true
"$V" ssh "pkill -f '/tmp/[w]ebgl-prof'; pkill -f '$G/[s]erver.py'; cat $G/commit" > "$OUT.commit" || true
"$V" ssh "cat $G/out.jsonl" > "$OUT.jsonl" || true
python3 - "$OUT.jsonl" "$OUT" "$VERSION" "$FILTER" "$status" "$(cat "$OUT.commit")" <<'PY'
import json, sys
src, out, version, filt, status, commit = sys.argv[1:7]
recs = [json.loads(l) for l in open(src) if l.strip()]
start = next((r for r in recs if r["kind"] == "start"), {})
first, last = {}, {}
for r in recs:
    if r["kind"] == "result":
        first.setdefault(r["test"], r)
        last[r["test"]] = r
res = list(last.values())
# failed in a Chrome that had already run a failing page, passed in a fresh one
victims = sorted(t for t in last if first[t]["status"] != "pass" and last[t]["status"] == "pass")
count = {k: sum(1 for r in res if r["status"] == k) for k in ("pass", "fail", "timeout", "hang")}
retried = sum(1 for r in res if r.get("attempt") == 2)
sub = {k: sum(r[k] for r in res) for k in ("pass", "fail", "skip")}
summary = {"suite": "webgl-conformance", "suite_version": "conformance-suites/2.0.0", "webgl": version,
           "khronos_webgl_commit": commit, "filter": filt, "run": status,
           "renderer": start.get("renderer"), "user_agent": start.get("userAgent"),
           "pages_listed": start.get("count"), "pages_run": len(res), "pages": count,
           "page_pass_rate": round(count["pass"] / len(res), 4) if res else None,
           "subtests": sub, "pages_retried_in_fresh_chrome": retried,
           "pages_passing_only_in_fresh_chrome": len(victims), "cascade_victims": victims,
           "subtest_pass_rate": round(sub["pass"] / (sub["pass"] + sub["fail"]), 4) if sub["pass"] + sub["fail"] else None,
           "failed_pages": [{"test": r["test"], "status": r["status"], "fail": r["fail"], "msgs": r["msgs"][:3]}
                            for r in res if r["status"] != "pass"]}
json.dump(summary, open(out, "w"), indent=1)
print(json.dumps({k: summary[k] for k in ("webgl", "run", "renderer", "pages_run", "pages", "subtests", "subtest_pass_rate")}))
PY
