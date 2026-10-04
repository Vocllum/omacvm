#!/bin/bash
# deqp.sh gles2|gles3|vk [--filter REGEX] [--exclude REGEX] [--stride N] [--env "K=V ..."] [--out FILE.json]
# Khronos dEQP from VK-GL-CTS, built in the guest (guest/build-cts.sh; no Arch ARM package).
# Case list: the CTS mustpass list for the API, then --filter (regex), then every Nth case
# (--stride) for a quick subset. vk = Vulkan CTS for Venus: start the VM with a Venus runtime
# (GPUX=",blob=true,venus=true,hostmem=4G" RT=...) and pass e.g. --env "VK_ICD_FILENAMES=...".
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); V="$H/vm.sh"
API=${1:?gles2|gles3|vk}; shift
FILTER=.; EXCLUDE=; STRIDE=1; ENVS=""; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --filter) FILTER=$2; shift 2;; --exclude) EXCLUDE=$2; shift 2;; --stride) STRIDE=$2; shift 2;; --env) ENVS=$2; shift 2;;
  --out) OUT=$2; shift 2;; *) echo "unknown: $1"; exit 2;; esac; done
OUT=${OUT:-$H/results/deqp-$API-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
C=/opt/vk-gl-cts; B=$C/build
"$V" ssh "test -x $B/modules/gles2/deqp-gles2" || { echo "CTS not built: run guest/build-cts.sh in the guest"; exit 1; }
case $API in
  gles2) BIN=$B/modules/gles2/deqp-gles2; LIST="gles2-main.txt";  ARGS="--deqp-surface-type=pbuffer --deqp-gl-config-name=rgba8888d24s8ms0 --deqp-surface-width=256 --deqp-surface-height=256";;
  gles3) BIN=$B/modules/gles3/deqp-gles3; LIST="gles3-main.txt";  ARGS="--deqp-surface-type=pbuffer --deqp-gl-config-name=rgba8888d24s8ms0 --deqp-surface-width=256 --deqp-surface-height=256";;
  vk)    BIN=$B/external/vulkancts/modules/vulkan/deqp-vk; LIST="vk-default.txt"; ARGS="";;
  *) echo "unknown api $API"; exit 2;;
esac
"$V" ssh "cat > $C/deqp-run.py" < "$H/guest/deqp-run.py"
# mustpass list (paths moved between CTS versions: find it), filter, stride
"$V" ssh "set -e; L=\$(find $C/src/external/openglcts/data $C/src/external/vulkancts/mustpass -path '*/main/$LIST' 2>/dev/null | head -1)
  [ -n \"\$L\" ] || { echo 'no mustpass list $LIST'; exit 1; }
  D=\$(dirname \$L); : > $C/$API-cases.txt
  # vk-default.txt is a list of list files
  if grep -q '\\.txt\$' \$L; then for f in \$(cat \$L); do cat \$D/\$f; done; else cat \$L; fi \
    | grep -E '$FILTER' | grep -vE '${EXCLUDE:-^\$}' | awk 'NR % $STRIDE == 1 || $STRIDE == 1' > $C/$API-cases.txt
  wc -l < $C/$API-cases.txt"
# dEQP surfaceless calls eglGetDisplay(NULL): without EGL_PLATFORM Mesa picks a window system
[[ $API == gles* ]] && ENVS="EGL_PLATFORM=surfaceless $ENVS"
# one failing case can poison the virgl context for the rest of the process: rerun after a Fail
ENVS="DEQP_ISOLATE=${DEQP_ISOLATE:-1} $ENVS"
T0=$(date +%s)
"$V" ssh "cat $C/$API-cases.txt" > "$OUT.cases"
# dEQP command lines stream per-case results to the host (OUT.events), so a case that takes
# QEMU down is known: it is recorded as HostCrash, the VM restarted and the rest continues.
: > "$OUT.events"; restarts=0
while :; do
  python3 - "$OUT.cases" "$OUT.events" > "$OUT.todo" <<'PY'
import json, sys
done = {json.loads(l)["case"] for l in open(sys.argv[2]) if l.strip() and json.loads(l)["status"] != "Running"}
print("\n".join(c.strip() for c in open(sys.argv[1]) if c.strip() and c.strip() not in done))
PY
  [ -s "$OUT.todo" ] && grep -q . "$OUT.todo" || break
  "$V" ssh "cat > $C/$API-todo.txt" < "$OUT.todo"; n0=$(wc -l < "$OUT.events")
  "$V" ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "cd $C; env $ENVS python3 $C/deqp-run.py $BIN $C/$API-todo.txt $ARGS" >> "$OUT.events" && break
  if "$V" ssh -o ConnectTimeout=10 true 2>/dev/null; then   # only ssh broke: go on
    [ "$(wc -l < "$OUT.events")" = "$n0" ] && { echo "deqp-run.py made no progress"; break; }
    "$V" ssh "pkill -f '[d]eqp-run.py'; pkill -f '[d]eqp-$API'"; continue
  fi
  last=$(tail -1 "$OUT.events" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}"); print(r.get("case","") if r.get("status")=="Running" else "")')
  p=$("$V" pid); how=HostCrash; [ -n "$p" ] && how=VMHang   # QEMU gone = it crashed
  echo "VM lost during ${last:-?} ($how), restarting"
  [ -n "$last" ] && echo "{\"case\": \"$last\", \"status\": \"$how\"}" >> "$OUT.events"
  restarts=$((restarts + 1)); [ $restarts -gt ${MAX_RESTARTS:-40} ] && { echo "too many VM restarts"; break; }
  p=$("$V" pid); [ -n "$p" ] && { kill "$p"; sleep 5; kill -9 "$p" 2>/dev/null; }
  cp "$("$V" log)" "$OUT.qemu-$restarts.log" 2>/dev/null
  "$V" start || { echo "VM did not restart"; break; }
done
python3 -c '
import json, sys
last = {}
for l in open(sys.argv[1]):
    if l.strip():
        r = json.loads(l)
        if r["status"] != "Running": last[r["case"]] = r["status"]
for c, s in last.items(): print(json.dumps({"case": c, "status": s}))' "$OUT.events" > "$OUT.jsonl"
COMMIT=$("$V" ssh "cat $C/commit")
RENDERER=$("$V" ssh "eglinfo -B 2>/dev/null | grep -m1 'OpenGL ES profile renderer' | cut -d: -f2-; vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | cut -d= -f2" | tr '\n' ' ')
python3 - "$OUT.jsonl" "$OUT" "$API" "$FILTER" "$STRIDE" "$COMMIT" "$RENDERER" "$(( $(date +%s) - T0 ))" <<'PY'
import collections, json, sys
src, out, api, filt, stride, commit, renderer, secs = sys.argv[1:9]
r = [json.loads(l) for l in open(src) if l.strip()]
c = collections.Counter(x["status"] for x in r)
ran = c["Pass"] + c["Fail"] + c["QualityWarning"] + c["CompatibilityWarning"] + c["Crash"] + c["Timeout"] + c["InternalError"] + c["ResourceError"] + c["HostCrash"] + c["VMHang"]
res = {"suite": f"deqp-{api}", "isolate_after_fail": __import__("os").environ.get("DEQP_ISOLATE", "1") == "1", "cts_commit": commit, "renderer": renderer.strip(), "filter": filt, "stride": int(stride),
       "cases": len(r), "status": dict(c), "seconds": int(secs),
       "pass_rate": round((c["Pass"] + c["QualityWarning"] + c["CompatibilityWarning"]) / ran, 4) if ran else None,
       "not_supported": c["NotSupported"],
       "failures": [x["case"] for x in r if x["status"] in ("Fail", "Crash", "HostCrash", "VMHang", "Timeout", "InternalError", "ResourceError")][:500]}
json.dump(res, open(out, "w"), indent=1)
print(json.dumps({k: res[k] for k in ("suite", "cases", "status", "pass_rate", "seconds")}))
PY
