#!/bin/bash
# scanout-churn.sh [--sizes "W1 H1 W2 H2"] [--switches N] [--step K] [--max-growth-mb M]
#                  [--budget-mb B] [--out FILE.json]
# The guest switches its scanout between two sizes (guest/alt-scanout.c, as root on VT2) while
# the Mac samples QEMU's "IOAccelerator (graphics)" memory and footprint between steps.
# Before qemu-cocoa-gl-view-flush.patch every mode change of a 4K screen or more left at least
# one screen texture in GPU memory (8000x6000 <-> 7000x5000 grew QEMU by ~1.1 GB per switch).
# The guest switches K at a time and waits for the Mac to measure, so the run is bounded by
# construction: it stops after N switches, or as soon as QEMU's footprint has grown by
# --budget-mb (default 2048) since the start; an old runtime overshoots by one step at most.
# Pass: every switch succeeded, and IOAccelerator grew less than --max-growth-mb (default 64)
# between the end of the first step (both sizes made once) and the end.
# Fails (exit 2) when QEMU's memory cannot be read, instead of passing on nothing.
# Needs a running test VM (vm.sh start). STANDARDS 18: refuses while ~/.omacvm-user-testing exists.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
SIZES="3840 2160 2560 1440"; SWITCHES=60; STEP=4; MAXG=64; BUDGET=2048; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --sizes) SIZES=$2; shift 2;; --switches) SWITCHES=$2; shift 2;; --step) STEP=$2; shift 2;;
  --max-growth-mb) MAXG=$2; shift 2;; --budget-mb) BUDGET=$2; shift 2;; --out) OUT=$2; shift 2;;
  *) echo "unknown: $1"; exit 2;; esac; done
[ -e "$HOME/.omacvm-user-testing" ] && { echo "the user is testing on this Mac: no VM tests here"; exit 3; }
OUT=${OUT:-$H/results/scanout-churn-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
V="$H/vm.sh"; P=$("$V" pid); [ -n "$P" ] || { echo "no test VM running (vm.sh start)"; exit 2; }

# "<IOAccelerator (graphics) dirty MB> <footprint MB>" from footprint(1) (MB precision; vmmap's
# summary rounds to 0.1 GB); "0 0" when it cannot read QEMU.
sample() {
  footprint -p "$P" 2>/dev/null | awk '
    function mb(n, u) { return u == "GB" ? n * 1024 : u == "MB" ? n : u == "KB" ? n / 1024 : n / 1048576 }
    /Footprint: / && !fp { for (i = 1; i < NF; i++) if ($i == "Footprint:") fp = mb($(i + 1), $(i + 2)) }
    /IOAccelerator \(graphics\)$/ { io = mb($1, $2) }
    END { printf "%.1f %.1f\n", io, fp }'
}
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# The guest's links to the Mac helpers stay off (STANDARDS 18).
"$V" ssh "systemctl mask --now omacvm-gestures >/dev/null 2>&1; \
  for u in \$(loginctl list-users --no-legend | awk '{print \$2}'); do \
  sudo -u \$u XDG_RUNTIME_DIR=/run/user/\$(id -u \$u) systemctl --user mask --now notchcast >/dev/null 2>&1; done; true"
"$V" ssh "cat > /root/alt-scanout.c" < "$H/guest/alt-scanout.c"
"$V" ssh "cd /root && cc -O2 -o alt-scanout alt-scanout.c \$(pkg-config --cflags --libs libdrm)" \
  || { echo "could not build alt-scanout in the guest (needs gcc + libdrm headers)"; exit 2; }

read -r IO0 FP0 < <(sample)
gt "$IO0" 0 && gt "$FP0" 0 || { echo "cannot read QEMU's memory with footprint (pid $P): no measurement"; exit 2; }
echo "start: IOAccelerator $IO0 MB, footprint $FP0 MB; $SWITCHES switches of $SIZES, $STEP per step"
# bash 3.2 (macOS) has no coproc: two FIFOs to the guest tool's stdin and stdout.
T=$(mktemp -d); mkfifo "$T/in" "$T/out"
"$V" ssh "chvt 2; sleep 1; /root/alt-scanout $SIZES step; chvt 1" < "$T/in" > "$T/out" 2>&1 &
G=$!
exec 3>"$T/in" 4<"$T/out"
DONE=0; FAILED=0; STOPPED=0; IOW=""; TRACE=""; ERR=""
while [ "$DONE" -lt "$SWITCHES" ]; do
  echo "$STEP" >&3
  line=""
  while read -r -t 120 line <&4; do [[ $line == done* ]] && break; echo "guest: $line"; done
  [[ $line == done* ]] || { ERR="no answer from the guest after $DONE switches"; break; }
  read -r _ DONE FAILED <<< "$line"
  read -r IO FP < <(sample)
  gt "$IO" 0 || { ERR="lost the measurement after $DONE switches"; break; }
  [ -z "$IOW" ] && IOW=$IO
  TRACE="$TRACE $DONE:$IO:$FP"
  if gt "$(awk -v f="$FP" -v f0="$FP0" 'BEGIN { print f - f0 }')" "$BUDGET"; then
    echo "footprint grew past $BUDGET MB after $DONE switches: stopping"
    STOPPED=1; break
  fi
done
exec 3>&-
[ -n "$ERR" ] && { kill "$G" 2>/dev/null; "$V" ssh "pkill -x alt-scanout; chvt 1" || true; }
cat <&4 >/dev/null; exec 4<&-
wait "$G" 2>/dev/null || true; rm -rf "$T"
sleep 2
read -r IO1 FP1 < <(sample)
python3 - "$OUT" "$SIZES" "$SWITCHES" "$STEP" "$MAXG" "$BUDGET" "$IO0" "$FP0" "${IOW:-0}" "$IO1" "$FP1" \
  "$DONE" "$FAILED" "$STOPPED" "$ERR" "$TRACE" <<'PY'
import json, sys
(out, sizes, want, step, maxg, budget, io0, fp0, iow, io1, fp1, done, failed, stopped, err,
 trace) = sys.argv[1:17]
done, failed, want = int(done), int(failed), int(want)
growth = float(io1) - float(iow)
pts = [t.split(":") for t in trace.split()]
res = {"test": "scanout-churn", "sizes": sizes, "switches_wanted": want, "step": int(step),
       "switches": done, "failed_switches": failed, "error": err or None,
       "ioaccelerator_mb": {"start": float(io0), "after_first_step": float(iow), "end": float(io1)},
       "footprint_mb": {"start": float(fp0), "end": float(fp1)},
       "growth_mb": round(growth, 1), "max_growth_mb": float(maxg),
       "growth_per_switch_mb": round(growth / max(done - int(step), 1), 2),
       "budget_mb": float(budget), "stopped_at_budget": stopped == "1",
       "trace": [{"switches": int(n), "ioaccelerator_mb": float(i), "footprint_mb": float(f)}
                 for n, i, f in pts]}
res["pass"] = (not err and done >= want and failed == 0 and not res["stopped_at_budget"]
               and float(iow) > 0 and growth < float(maxg))
json.dump(res, open(out, "w"), indent=1)
print(json.dumps({k: res[k] for k in ("switches", "failed_switches", "growth_mb", "growth_per_switch_mb",
                                      "ioaccelerator_mb", "stopped_at_budget", "error", "pass")}))
sys.exit(0 if res["pass"] else 1)
PY
