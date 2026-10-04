#!/bin/bash
# soak.sh [--minutes 30] [--interval 15] [--vk] [--out FILE.json]
# Load: glmark2 loop (vkmark with --vk), Chrome on a WebGL page, mpv looping a 1080p video.
# Every interval: guest heartbeat over SSH, progress of each load, virtio-gpu fences
# (debugfs: signalled vs emitted), QEMU CPU% and RSS, new QEMU log lines.
# A hang (no heartbeat 2x, a fence stuck 45 s, or all loads stalled 90 s) stops the run and
# collects: QEMU stack samples, QEMU log, guest dmesg if reachable. Results as JSON.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); V="$H/vm.sh"
MIN=30; IV=15; VK=0; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --minutes) MIN=$2; shift 2;; --interval) IV=$2; shift 2;; --vk) VK=1; shift;;
  --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
OUT=${OUT:-$H/results/soak-$(date +%Y%m%d-%H%M%S).json}; ART=${OUT%.json}; mkdir -p "$ART"
QPID=$("$V" pid); [ -z "$QPID" ] && { echo "VM not running"; exit 1; }
QLOG=$("$V" log); QLOG0=$(wc -l < "$QLOG")
G=/tmp/omacvm-soak

# Loads (guest, as the desktop user; all stop by themselves after MIN minutes + margin)
"$V" ssh "rm -rf $G; mkdir -p $G; chmod 777 $G"
"$V" ssh "cat > $G/webgl.html" < "$H/guest/soak-webgl.html"
"$V" ssh "cat > $G/server.py" < "$H/guest/soak-server.py"
"$V" ssh "cat > $G/probe.py" < "$H/guest/soak-probe.py"
"$V" ssh "ffmpeg -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 20 -c:v libx264 -pix_fmt yuv420p $G/v.mp4"
"$V" ssh "chown -R \$(id -un 1000) $G"
T=$(( MIN*60 + 60 ))
if [ $VK = 1 ]; then GPUJOB="vkmark --winsys wayland"; else GPUJOB="glmark2-es2-wayland"; fi
"$V" session bash -c "cd $G; nohup timeout $T python3 server.py >/dev/null 2>&1 &
  nohup timeout $T bash -c 'while :; do $GPUJOB >> $G/gpu.txt 2>&1; echo LOOP >> $G/gpu.txt; done' >/dev/null 2>&1 &
  nohup timeout $T google-chrome-stable --user-data-dir=$G/prof --no-first-run --ozone-platform=wayland --disable-background-timer-throttling --disable-renderer-backgrounding http://127.0.0.1:8766/webgl.html >/dev/null 2>&1 &
  nohup timeout $T mpv --loop=inf --hwdec=auto --really-quiet --vo=gpu --input-ipc-server=$G/mpv.sock $G/v.mp4 > $G/mpv.txt 2>&1 &"

sample_qemu() { sample "$QPID" 3 1 -file "$ART/qemu-sample-$1.txt" >/dev/null 2>&1; }
end=$(( $(date +%s) + MIN*60 )); verdict=pass; why=""; misses=0; paused=0
last_sig=-1; sig_since=$(date +%s); last_prog=""; prog_since=$(date +%s)
: > "$ART/samples.jsonl"
while [ "$(date +%s)" -lt $end ]; do
  sleep "$IV"; now=$(date +%s)
  if ! kill -0 "$QPID" 2>/dev/null; then verdict=fail; why="QEMU exited"; break; fi
  # paused by a benchmark run (kill -STOP, standards section 10): not a hang, stretch the run
  if [[ $(ps -o stat= -p "$QPID") == T* ]]; then
    end=$((end + IV)); sig_since=$now; prog_since=$now; paused=$((paused + IV)); continue
  fi
  read -r cpu rss < <(ps -o %cpu=,rss= -p "$QPID")
  g=$("$V" ssh -o ConnectTimeout=8 "python3 $G/probe.py $G" 2>/dev/null)
  if [ -z "$g" ]; then
    misses=$((misses+1)); echo "{\"t\":$now,\"heartbeat\":false,\"qemu_cpu\":$cpu,\"qemu_rss_kb\":$rss}" >> "$ART/samples.jsonl"
    [ $misses -ge 2 ] && { verdict=fail; why="no guest heartbeat for $((2*IV)) s"; sample_qemu hang; break; }
    continue
  fi
  misses=0
  read -r sig emit loops wf mf md mem lit <<< "$g"
  echo "{\"t\":$now,\"heartbeat\":true,\"fence_signalled\":$sig,\"fence_emitted\":$emit,\"gpu_loops\":$loops,\"webgl_frames\":$wf,\"video_frame\":$mf,\"video_drops\":$md,\"guest_mem_avail_kb\":$mem,\"webgl_lit\":${lit:-0},\"qemu_cpu\":$cpu,\"qemu_rss_kb\":$rss}" >> "$ART/samples.jsonl"
  if [ "$sig" != "$last_sig" ] || [ "$sig" = "$emit" ]; then last_sig=$sig; sig_since=$now; fi
  [ $((now - sig_since)) -ge 45 ] && { verdict=fail; why="fence $sig stuck 45 s (emitted $emit)"; sample_qemu fence; break; }
  prog="$loops/$wf/$mf"
  if [ "$prog" != "$last_prog" ]; then last_prog=$prog; prog_since=$now; fi
  [ $((now - prog_since)) -ge 90 ] && { verdict=fail; why="no progress in any load for 90 s"; sample_qemu stall; break; }
done
tail -n +"$((QLOG0+1))" "$QLOG" > "$ART/qemu.log"
"$V" ssh -o ConnectTimeout=8 "dmesg | tail -200" > "$ART/guest-dmesg.txt" 2>/dev/null
"$V" ssh -o ConnectTimeout=8 "grep -E 'Score' $G/gpu.txt" > "$ART/gpu-scores.txt" 2>/dev/null
"$V" session bash -c "pkill -f '$G/[p]rof'; pkill -f '$G/[v].mp4'; pkill -f '[g]lmark2|[v]kmark'; pkill -f '$G/[s]erver.py'" >/dev/null 2>&1
python3 - "$ART" "$OUT" "$verdict" "$why" "$MIN" "$VK" "$paused" <<'PY'
import json, re, sys
art, out, verdict, why, mins, vk, paused = sys.argv[1:8]
s = [json.loads(l) for l in open(f"{art}/samples.jsonl")]
ok = [x for x in s if x.get("heartbeat")]
scores = [int(m) for m in re.findall(r"Score: (\d+)", open(f"{art}/gpu-scores.txt").read())]
qlog = [l for l in open(f"{art}/qemu.log") if l.strip()]
rss = [x["qemu_rss_kb"] for x in s]
res = {"suite": "soak", "verdict": verdict, "reason": why, "minutes_planned": int(mins),
       "seconds_run": s[-1]["t"] - s[0]["t"] if len(s) > 1 else 0, "gpu_load": "vkmark" if vk == "1" else "glmark2-es2-wayland",
       "seconds_paused_by_bench": int(paused), "samples": len(s), "heartbeat_misses": len(s) - len(ok),
       "gpu_loops": ok[-1]["gpu_loops"] if ok else 0, "gpu_scores": scores,
       "webgl_frames": ok[-1]["webgl_frames"] if ok else 0,
       # share of non-black pixels the WebGL page read back (0 = it renders nothing)
       "webgl_lit_min_max": [min(x.get("webgl_lit", 0) for x in ok), max(x.get("webgl_lit", 0) for x in ok)] if ok else None,
       "video_frame": ok[-1]["video_frame"] if ok else 0, "video_drops": ok[-1]["video_drops"] if ok else 0,
       "fences_signalled": (ok[-1]["fence_signalled"] - ok[0]["fence_signalled"]) if ok else 0,
       "qemu_rss_mb_first_last_max": [rss[0] // 1024, rss[-1] // 1024, max(rss) // 1024] if rss else None,
       "qemu_cpu_avg": round(sum(x["qemu_cpu"] for x in s) / len(s), 1) if s else None,
       "guest_mem_avail_mb_first_last": [ok[0]["guest_mem_avail_kb"] // 1024, ok[-1]["guest_mem_avail_kb"] // 1024] if ok else None,
       "qemu_log_new_lines": len(qlog), "qemu_log_tail": [l.rstrip() for l in qlog[-10:]],
       "artifacts": art}
json.dump(res, open(out, "w"), indent=1)
print(json.dumps({k: res[k] for k in ("verdict", "reason", "seconds_run", "gpu_loops", "webgl_frames", "video_frame", "video_drops", "fences_signalled", "qemu_rss_mb_first_last_max")}))
PY
[ $verdict = pass ]
