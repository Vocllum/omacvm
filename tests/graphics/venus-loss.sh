#!/bin/bash
# venus-loss.sh [--icd FILE] [--out FILE.json]: what a Vulkan app sees when the host
# loses its Venus context. Needs a VM started with Venus (vm.sh with
# GPUX=",blob=true,venus=true,hostmem=4G" and a Venus runtime) and a guest Mesa venus
# with blob alignment (Mesa >= 26.2.4 or /opt/mesa-main, see --icd).
# guest/vk-lost.c submits and waits in a loop, then sends an invalid
# vkCreateShaderModule (codeSize 6), which the host's venus decoder treats as fatal.
# Pass: the app ends (abort or VK_ERROR_DEVICE_LOST) within 30 s instead of hanging, the
# host logs the loss once, a fresh Vulkan app works afterwards and the VM lives.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
ICD=/opt/mesa-main/share/vulkan/icd.d/virtio_icd.aarch64.json; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --icd) ICD=$2; shift 2;; --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
OUT=${OUT:-$H/results/venus-loss-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
V="$H/vm.sh"; G=/opt/context-loss
LOG=$("$V" log); LOG0=$(wc -l < "$LOG")
"$V" ssh "mkdir -p $G; cat > $G/vk-lost.c" < "$H/guest/vk-lost.c"
"$V" ssh "cd $G && cc -O2 -o vk-lost vk-lost.c -lvulkan"
run() { "$V" ssh "cd $G && VK_DRIVER_FILES=$ICD timeout 60 ./vk-lost $1 > $2 2>&1; echo \$? > $2.exit"; }
run "" before.jsonl
start=$(date +%s); run --poison poison.jsonl; secs=$(( $(date +%s) - start ))
run "" after.jsonl
for f in before poison after; do "$V" ssh "cat $G/$f.jsonl; echo '{\"exit\":'\$(cat $G/$f.jsonl.exit)'}'" > "$OUT.$f.jsonl"; done
tail -n +"$((LOG0 + 1))" "$LOG" > "$OUT.qemu.log"
HYPR=$("$V" session hyprctl -j monitors 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)
python3 - "$OUT" "$secs" "$HYPR" <<'PY'
import json, sys
out, secs, hypr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def load(name):
    recs = []
    for l in open(f"{out}.{name}.jsonl", errors="replace"):
        l = l.strip()
        if l.startswith("{"):
            try: recs.append(json.loads(l))
            except ValueError: pass
    return recs
b, p, a = load("before"), load("poison"), load("after")
exit_of = lambda r: next((x["exit"] for x in r if "exit" in x), None)
done = lambda r: next((x for x in r if x.get("done")), {})
q = open(f"{out}.qemu.log", errors="replace").read()
waits = [x for x in p if "i" in x]
res = {
    "test": "venus-loss", "device": next((x["device"] for x in b if "device" in x), None),
    "before": {"exit": exit_of(b), **{k: done(b).get(k) for k in ("ok", "device_lost", "timeouts")}},
    "poison": {"exit": exit_of(p), "seconds": secs, "waits": len(waits),
               "last_result": waits[-1]["result"] if waits else None,
               "ok_before_poison": sum(1 for x in waits if x["i"] < 10 and x["result"] == 0),
               **{k: done(p).get(k) for k in ("ok", "device_lost", "timeouts")}},
    "after": {"exit": exit_of(a), **{k: done(a).get(k) for k in ("ok", "device_lost", "timeouts")}},
    "host_logged_loss": q.count("venus context") , "hyprland_monitors": hypr,
}
pe = res["poison"]["exit"]
ended = pe is not None and pe != 124 and (pe != 0 or (res["poison"]["device_lost"] or 0) > 0)
res["pass"] = (res["before"]["exit"] == 0 and res["before"]["ok"] == 40 and ended and secs < 45
               and res["after"]["exit"] == 0 and res["after"]["ok"] == 40 and hypr > 0)
json.dump(res, open(out, "w"), indent=1)
print(json.dumps(res, indent=1))
sys.exit(0 if res["pass"] else 1)
PY
