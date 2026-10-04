#!/usr/bin/env python3
"""Guest side: run a dEQP binary over a case list, restart after a crash or hang
(the crashed case is recorded and skipped), write one JSON line per case.
Usage: deqp-run.py BINARY CASELIST OUT.jsonl [extra dEQP args...]"""
import json, os, re, subprocess, sys, tempfile

binary, caselist, out = sys.argv[1:4]
extra = sys.argv[4:]
cases = [c.strip() for c in open(caselist) if c.strip()]
done = {}
if os.path.exists(out):
    for l in open(out):
        r = json.loads(l)
        done[r["case"]] = r["status"]
todo = [c for c in cases if c not in done]
os.chdir(os.path.dirname(os.path.abspath(binary)))  # dEQP finds its data next to the binary
with open(out, "a") as o:
    while todo:
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("\n".join(todo))
            cl = f.name
        qpa = cl + ".qpa"
        try:
            subprocess.run([binary, f"--deqp-caselist-file={cl}", f"--deqp-log-filename={qpa}",
                            "--deqp-log-images=disable", "--deqp-log-shader-sources=disable",
                            "--deqp-watchdog=enable"] + extra,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60 * 60)
        except subprocess.TimeoutExpired:
            pass
        text = open(qpa, errors="replace").read() if os.path.exists(qpa) else ""
        seen = set()
        for m in re.finditer(r"#beginTestCaseResult (\S+)(.*?)(#endTestCaseResult|#terminateTestCaseResult (\S+)|\Z)", text, re.S):
            case, body, end, term = m.group(1), m.group(2), m.group(3), m.group(4)
            if term or not end:
                status = term or "Crash"
            else:
                s = re.search(r'StatusCode="(\w+)"', body)
                status = s.group(1) if s else "Unknown"
            seen.add(case)
            o.write(json.dumps({"case": case, "status": status}) + "\n")
            o.flush()
        rest = [c for c in todo if c not in seen]
        if len(rest) == len(todo):  # nothing ran: record the first case as a crash and move on
            o.write(json.dumps({"case": rest[0], "status": "Crash"}) + "\n")
            rest = rest[1:]
        todo = rest
        os.unlink(cl)
        if os.path.exists(qpa):
            os.unlink(qpa)
