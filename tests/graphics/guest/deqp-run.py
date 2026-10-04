#!/usr/bin/env python3
"""Guest side: run a dEQP binary over a case list, restart after a crash or hang
(the crashed case is recorded and skipped). dEQP writes its log into a pipe; each case is
printed as one JSON line on stdout as soon as it is known, plus {"status": "Running"} when
it starts, so the host still knows the case if the whole VM dies (QEMU crash).
With DEQP_ISOLATE=1 dEQP is restarted after every failing case: on virgl one failed shader
compile puts the whole guest context in error and every later case in that process fails too.
Usage: deqp-run.py BINARY CASELIST [extra dEQP args...]"""
import json, os, re, subprocess, sys, tempfile

binary, caselist = sys.argv[1:3]
extra = sys.argv[3:]
isolate = os.environ.get("DEQP_ISOLATE") == "1"
todo = [c.strip() for c in open(caselist) if c.strip()]
os.chdir(os.path.dirname(os.path.abspath(binary)))  # dEQP finds its data next to the binary


def emit(case, status):
    print(json.dumps({"case": case, "status": status}), flush=True)


while todo:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(todo))
        cl = f.name
    r, w = os.pipe()
    p = subprocess.Popen([binary, f"--deqp-caselist-file={cl}", f"--deqp-log-filename=/dev/fd/{w}",
                          "--deqp-log-images=disable", "--deqp-log-shader-sources=disable",
                          "--deqp-watchdog=enable"] + extra,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(w,))
    os.close(w)
    seen, case, body = set(), None, []
    for line in os.fdopen(r, errors="replace"):
        if line.startswith("#beginTestCaseResult "):
            case, body = line.split()[1], []
            emit(case, "Running")
        elif line.startswith("#terminateTestCaseResult ") and case:
            emit(case, line.split()[1])
            seen.add(case); case = None
        elif line.startswith("#endTestCaseResult") and case:
            s = re.search(r'StatusCode="(\w+)"', "".join(body))
            status = s.group(1) if s else "Unknown"
            emit(case, status)
            seen.add(case); case = None
            if isolate and status == "Fail":
                p.kill()
                break
        elif case:
            body.append(line)
    p.wait()
    if case:  # dEQP died inside this case
        emit(case, "Crash")
        seen.add(case)
    elif not seen:  # nothing ran: record the first case and move on
        emit(todo[0], "Crash")
        seen.add(todo[0])
    todo = [c for c in todo if c not in seen]
    os.unlink(cl)
