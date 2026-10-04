#!/bin/bash
# scanout-churn.sh [--sizes "W1 H1 W2 H2"] [--seconds N] [--max-growth-mb M] [--budget-mb B] [--out FILE.json]
# The guest switches its scanout between two sizes as fast as it can (guest/alt-scanout.c, as
# root on VT2) while the Mac samples QEMU's "IOAccelerator (graphics)" memory and footprint.
# Before qemu-cocoa-gl-view-flush.patch every mode change of a 4K screen or more left a screen
# texture in GPU memory (8000x6000 <-> 7000x5000: ~1.1 GB per switch, 20 GB after 18).
# Pass: IOAccelerator grows less than --max-growth-mb (default 64) from the first sample.
# Safety: the churn is stopped as soon as QEMU's footprint grows by --budget-mb (default 2048),
# so an old runtime cannot use up the Mac. Keep the default sizes on a 16 GB Mac.
# Needs a running test VM (vm.sh start; use OMACVM_COCOA_HIDDEN=1 where the runtime has it).
# STANDARDS 18: refuses to run while ~/.omacvm-user-testing exists.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
SIZES="3840 2160 2560 1440"; SECS=15; MAXG=64; BUDGET=2048; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --sizes) SIZES=$2; shift 2;; --seconds) SECS=$2; shift 2;; --max-growth-mb) MAXG=$2; shift 2;;
  --budget-mb) BUDGET=$2; shift 2;; --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
[ -e "$HOME/.omacvm-user-testing" ] && { echo "the user is testing on this Mac: no VM tests here"; exit 3; }
OUT=${OUT:-$H/results/scanout-churn-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
V="$H/vm.sh"; P=$("$V" pid); [ -n "$P" ] || { echo "no test VM running (vm.sh start)"; exit 2; }

# MB of a vmmap size like 12.5G / 300M / 16K.
mb() { awk -v s="$1" 'BEGIN { u = substr(s, length(s)); n = s + 0
  print (u == "G" ? n * 1024 : u == "M" ? n : u == "K" ? n / 1024 : n / 1048576) }'; }
sample() {  # "<IOAccelerator dirty MB> <footprint MB>"
  vmmap -summary "$P" 2>/dev/null | awk '
    /^IOAccelerator \(graphics\)/ { io = $5 }
    /^Physical footprint: / { fp = $3 }
    END { print (io == "" ? "0K" : io), fp }' | { read -r io fp; echo "$(mb "$io") $(mb "$fp")"; }
}

# The guest's links to the Mac helpers stay off (STANDARDS 18).
"$V" ssh "systemctl mask --now omacvm-gestures >/dev/null 2>&1; \
  for u in \$(loginctl list-users --no-legend | awk '{print \$2}'); do \
  sudo -u \$u XDG_RUNTIME_DIR=/run/user/\$(id -u \$u) systemctl --user mask --now notchcast >/dev/null 2>&1; done; true"
"$V" ssh "cat > /root/alt-scanout.c" < "$H/guest/alt-scanout.c"
"$V" ssh "cd /root && cc -O2 -o alt-scanout alt-scanout.c \$(pkg-config --cflags --libs libdrm)" \
  || { echo "could not build alt-scanout in the guest (needs gcc + libdrm headers)"; exit 2; }

read -r IO0 FP0 < <(sample)
echo "start: IOAccelerator $IO0 MB, footprint $FP0 MB; churn $SIZES for $SECS s"
"$V" ssh "chvt 2; sleep 1; /root/alt-scanout $SIZES $SECS; chvt 1" > "$OUT.guest.txt" 2>&1 &
G=$!
PEAK=$IO0; STOPPED=0; TRACE=""
while kill -0 $G 2>/dev/null; do
  read -r IO FP < <(sample)
  TRACE="$TRACE $IO"
  awk -v a="$IO" -v b="$PEAK" 'BEGIN { exit !(a > b) }' && PEAK=$IO
  if awk -v f="$FP" -v f0="$FP0" -v b="$BUDGET" 'BEGIN { exit !(f - f0 > b) }'; then
    echo "footprint grew past $BUDGET MB: stopping the churn"
    "$V" ssh "pkill -f /root/[a]lt-scanout; chvt 1" || true
    STOPPED=1; break
  fi
  sleep 0.5
done
wait $G 2>/dev/null || true
sleep 2
read -r IO1 FP1 < <(sample)
python3 - "$OUT" "$SIZES" "$SECS" "$MAXG" "$BUDGET" "$IO0" "$FP0" "$IO1" "$FP1" "$PEAK" "$STOPPED" "$OUT.guest.txt" "$TRACE" <<'PY'
import json, re, sys
out, sizes, secs, maxg, budget, io0, fp0, io1, fp1, peak, stopped, gtxt, trace = sys.argv[1:14]
g = open(gtxt, errors="replace").read()
m = re.search(r"(\d+) switches in (\d+) s .*?(\d+) failed", g)
growth = float(io1) - float(io0)
res = {"test": "scanout-churn", "sizes": sizes, "seconds": int(secs),
       "switches": int(m.group(1)) if m else None, "failed_switches": int(m.group(3)) if m else None,
       "ioaccelerator_mb": {"start": float(io0), "end": float(io1), "peak": float(peak)},
       "footprint_mb": {"start": float(fp0), "end": float(fp1)},
       "growth_mb": round(growth, 1), "max_growth_mb": float(maxg),
       "stopped_at_budget": stopped == "1", "trace_mb": [float(x) for x in trace.split()]}
res["pass"] = bool(m) and res["switches"] > 0 and not res["stopped_at_budget"] and growth < float(maxg)
json.dump(res, open(out, "w"), indent=1)
print(json.dumps({k: res[k] for k in ("switches", "growth_mb", "ioaccelerator_mb", "stopped_at_budget", "pass")}))
sys.exit(0 if res["pass"] else 1)
PY
