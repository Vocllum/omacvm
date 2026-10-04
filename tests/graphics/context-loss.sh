#!/bin/bash
# context-loss.sh --expect contain|recover|dead [--mesa DIR] [--seconds N] [--out FILE.json]
# A WebGL page in Chrome (guest Hyprland session) draws and reads back every frame; after
# 5 s it also draws with a shader that a test build of the runtime refuses on the Mac
# (OMACVM_VIRGL_TEST_FAIL_GLSL=4242.25, set when the VM was started). Checks what follows:
#   contain  (default runtime): no context loss, the page keeps drawing correctly
#   recover  (OMACVM_VIRGL_SHADER_FAILURES=lose + guest Mesa with the reset status patch,
#            --mesa /opt/mesa-robust): webglcontextlost, then restored, then correct frames
#   dead     (lose, stock guest Mesa): the old failure, the page draws into a dead context
# Also checks that the VM and another GL client still work afterwards. Exit 0 = expectation met.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
EXPECT=""; MESA=""; SECS=40; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --expect) EXPECT=$2; shift 2;; --mesa) MESA=$2; shift 2;;
  --seconds) SECS=$2; shift 2;; --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
[[ $EXPECT =~ ^(contain|recover|dead)$ ]] || { echo "--expect contain|recover|dead"; exit 2; }
OUT=${OUT:-$H/results/context-loss-$EXPECT-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
V="$H/vm.sh"; G=/opt/context-loss; PROF=/tmp/context-loss-prof
# pkill -f patterns with [] so they never match the ssh shell that runs them
PROFPAT=/tmp/[c]ontext-loss-prof
LOG=$("$V" log); LOG0=$(wc -l < "$LOG")

ENVS=""
[ -n "$MESA" ] && ENVS="LD_LIBRARY_PATH=$MESA/lib GBM_BACKENDS_PATH=$MESA/lib/gbm"
"$V" ssh "mkdir -p $G; cat > $G/server.py" < "$H/guest/context-loss-server.py"
"$V" ssh "cat > $G/page.html" < "$H/guest/context-loss.html"
"$V" ssh "pkill -f '$G/[s]erver.py'; pkill -f '$PROFPAT'" || true
"$V" ssh "rm -rf $PROF $G/out.jsonl; nohup python3 $G/server.py $G/page.html $G/out.jsonl 8766 >/dev/null 2>&1 &"
sleep 1
"$V" session bash -c "nohup env $ENVS google-chrome-stable --user-data-dir=$PROF --no-first-run --no-default-browser-check --ozone-platform=wayland --disable-background-timer-throttling --disable-renderer-backgrounding 'http://127.0.0.1:8766/' >/tmp/context-loss-chrome.log 2>&1 &"
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt $end ]; do
  # paused by another track's benchmark (kill -STOP): wait that out too
  [[ $(ps -o stat= -p "$("$V" pid)") == T* ]] && end=$((end + 5))
  sleep 5
done
# Which Mesa did the GPU process load? (proves --mesa reached it)
# Chrome's GPU processes of this profile (a restarted one has other arguments)
GPUPIDS="for p in \$(pgrep -f 'type=[g]pu-process'); do grep -qa context-loss-prof /proc/\$p/cmdline /proc/\$p/environ 2>/dev/null && echo \$p; done"
GALLIUM=$("$V" ssh "for p in \$($GPUPIDS); do grep -o '/[^ ]*libgallium[^ ]*' /proc/\$p/maps | sort -u | tr '\n' ' '; done" || true)
GPUPROCS=$("$V" ssh "$GPUPIDS | wc -l" || echo 0)
"$V" ssh "pkill -f '$PROFPAT'; sleep 1; pkill -f '$G/[s]erver.py'" || true
"$V" ssh "cat $G/out.jsonl" > "$OUT.jsonl"
# The VM and other GL clients must live on: Hyprland answers, a fresh GL app renders.
HYPR=$("$V" session hyprctl -j monitors 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)
GLMARK=$("$V" session glmark2-es2-wayland --off-screen -b build:duration=2 2>&1 | sed -n 's/.*glmark2 Score: *\([0-9]*\).*/\1/p' || true)
tail -n +"$((LOG0 + 1))" "$LOG" > "$OUT.qemu.log"
python3 - "$OUT.jsonl" "$OUT.qemu.log" "$OUT" "$EXPECT" "$MESA" "$GALLIUM" "$GPUPROCS" "$HYPR" "${GLMARK:-0}" <<'PY'
import json, sys
src, qlog, out, expect, mesa, gallium, gpuprocs, hypr, glmark = sys.argv[1:10]
recs = [json.loads(l) for l in open(src) if l.strip()]
q = open(qlog, errors="replace").read()
start = next((r for r in recs if r["kind"] == "start"), {})
beats = [r for r in recs if r["kind"] == "beat"]
events = [r for r in recs if r["kind"] == "event"]
lost = [e for e in events if e["event"] == "lost"]
restored = [e for e in events if e["event"] == "restored"]
poison_at = start.get("poison_at", 5000)

def window(t_from):
    """Frames and readbacks from 2 s after t_from to the end of the run."""
    b = [x for x in beats if x["t"] >= t_from + 2000]
    if len(b) < 2:
        return {"seconds": 0, "frames": 0, "good": 0, "bad": 0}
    return {"seconds": round((b[-1]["t"] - b[0]["t"]) / 1000, 1), "frames": b[-1]["frame"] - b[0]["frame"],
            "good": sum(x["good"] for x in b[1:]), "bad": sum(x["bad"] for x in b[1:])}

before = [x for x in beats if x["t"] < poison_at]
res = {
    "test": "context-loss", "expect": expect, "guest_mesa": mesa or "system", "gpu_process_gallium": gallium.strip(),
    "renderer": start.get("renderer"), "user_agent": start.get("userAgent"),
    "beats": len(beats), "poison_draws": beats[-1]["poisonDraws"] if beats else 0,
    "before_poison": {"frames": before[-1]["frame"] if before else 0,
                      "good": sum(x["good"] for x in before), "bad": sum(x["bad"] for x in before)},
    "after_poison": window(poison_at),
    "lost_events": len(lost), "restored_events": len(restored),
    "lost_at_ms": lost[0]["t"] if lost else None, "restored_at_ms": restored[0]["t"] if restored else None,
    "after_restore": window(restored[0]["t"]) if restored else None,
    "renderer_after_restore": restored[0].get("renderer") if restored else None,
    "host_refused_shader": "refusing a shader on purpose" in q,
    "host_contained": "draws that need it are skipped" in q,
    "host_context_lost": "is lost, it draws nothing" in q,
    "host_told_guest": "the guest driver was told" in q,
    "host_log_lines": q.count("\n"),
    "gpu_processes_at_end": int(gpuprocs or 0), "hyprland_monitors": int(hypr or 0), "glmark2_after": int(glmark or 0),
}
ap, ar = res["after_poison"], res["after_restore"] or {}
alive = res["hyprland_monitors"] > 0 and res["glmark2_after"] > 0
checks = {
    "contain": [res["host_refused_shader"], res["host_contained"], not res["host_context_lost"],
                res["lost_events"] == 0, ap["frames"] > 10, ap["good"] > 10, ap["bad"] == 0],
    "recover": [res["host_refused_shader"], res["host_context_lost"], res["host_told_guest"],
                res["lost_events"] >= 1, res["restored_events"] >= 1,
                "virgl" in (res["renderer_after_restore"] or ""),
                ar.get("frames", 0) > 10, ar.get("good", 0) > 10, ar.get("bad", 1) == 0],
    "dead":    [res["host_refused_shader"], res["host_context_lost"], res["restored_events"] == 0,
                ap["good"] == 0],
}[expect] + [alive, res["before_poison"]["good"] > 0]
res["pass"] = all(checks)
json.dump(res, open(out, "w"), indent=1)
print(json.dumps(res, indent=1))
sys.exit(0 if res["pass"] else 1)
PY
