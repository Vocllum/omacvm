#!/bin/bash
# run-all.sh LABEL: start the VM on $RT, run every GL suite, stop the VM.
# Results: results/LABEL/{webgl1,webgl2,deqp-gles2,deqp-gles3,soak}.json (+ raw files).
# Same env as vm.sh (VM, RT, PORT, ...). SUITES limits the run, e.g. SUITES="webgl1 soak".
set -u
H=$(cd "$(dirname "$0")" && pwd); L=${1:?label}; R="$H/results/$L"; mkdir -p "$R"
SUITES=${SUITES:-webgl1 webgl2 gles2 gles3 soak}
log() { echo "$(date +%T) $L: $*" | tee -a "$R/run.log"; }
"$H/vm.sh" start >> "$R/run.log" 2>&1 || { log "VM did not start"; exit 1; }
log "VM up, runtime $RT"
for s in $SUITES; do
  log "start $s"
  case $s in
    webgl1) "$H/webgl.sh" --version 1.0.4 --minutes 120 --out "$R/webgl1.json" ;;
    webgl2) "$H/webgl.sh" --version 2.0.0 --filter '^conformance2/' --minutes 180 --out "$R/webgl2.json" ;;
    gles2)  "$H/deqp.sh" gles2 --stride 20 --out "$R/deqp-gles2.json" ;;
    gles3)  "$H/deqp.sh" gles3 --stride 50 --out "$R/deqp-gles3.json" ;;
    soak)   "$H/soak.sh" --minutes 30 --out "$R/soak.json" ;;
  esac >> "$R/run.log" 2>&1
  log "end $s (exit $?): $(tail -1 "$R/run.log")"
  # a suite that hung the guest leaves nothing to test on: restart the VM
  if ! "$H/vm.sh" ssh true 2>/dev/null; then
    log "guest unreachable after $s, restarting VM"
    kill "$("$H/vm.sh" pid)" 2>/dev/null; sleep 5
    "$H/vm.sh" start >> "$R/run.log" 2>&1 || { log "VM did not restart"; exit 1; }
  fi
done
"$H/vm.sh" stop
log "done"
