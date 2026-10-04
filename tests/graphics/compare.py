#!/usr/bin/env python3
"""compare.py BASE_DIR NEW_DIR: per-case differences between two run-all.sh result folders.
Prints, per suite, the counts on each side, the cases that pass in BASE and not in NEW
(regressions) and the other way round (fixes). WebGL compares pages and their subtest counts,
dEQP compares case status. Writes NEW_DIR/compare.json too."""
import json, os, sys


def load(path):
    if not os.path.exists(path):
        return None
    out = {}
    for line in open(path):
        if not line.strip():
            continue
        r = json.loads(line)
        if "kind" in r:  # WebGL page
            if r["kind"] == "result":
                out[r["test"]] = {"ok": r["status"] == "pass", "status": r["status"],
                                  "detail": f'{r["pass"]}/{r["pass"] + r["fail"]}',
                                  "msg": (r["msgs"] or [""])[0][:160]}
        else:  # dEQP case
            ok = r["status"] in ("Pass", "QualityWarning", "CompatibilityWarning", "NotSupported")
            out[r["case"]] = {"ok": ok, "status": r["status"], "detail": r["status"], "msg": ""}
    return out


base, new = sys.argv[1:3]
report = {}
for name in ("webgl1", "webgl2", "deqp-gles2", "deqp-gles3", "deqp-vk"):
    a, b = load(f"{base}/{name}.json.jsonl"), load(f"{new}/{name}.json.jsonl")
    if a is None or b is None:
        continue
    common = sorted(set(a) & set(b))
    reg = [c for c in common if a[c]["ok"] and not b[c]["ok"]]
    fix = [c for c in common if not a[c]["ok"] and b[c]["ok"]]
    # same status but fewer passing subtests (WebGL pages fail with different counts)
    worse = [c for c in common if not a[c]["ok"] and not b[c]["ok"] and a[c]["detail"] != b[c]["detail"]]
    report[name] = {
        "base_ok": sum(a[c]["ok"] for c in a), "base_cases": len(a),
        "new_ok": sum(b[c]["ok"] for c in b), "new_cases": len(b),
        "only_in_base": len(set(a) - set(b)), "only_in_new": len(set(b) - set(a)),
        "regressions": [{"case": c, "base": a[c]["detail"], "new": b[c]["detail"], "msg": b[c]["msg"]} for c in reg],
        "fixes": [{"case": c, "base": a[c]["detail"], "new": b[c]["detail"]} for c in fix],
        "both_fail_differently": [{"case": c, "base": a[c]["detail"], "new": b[c]["detail"]} for c in worse],
    }
    r = report[name]
    print(f"{name}: base {r['base_ok']}/{r['base_cases']} ok, new {r['new_ok']}/{r['new_cases']} ok, "
          f"{len(reg)} regressions, {len(fix)} fixes, {len(worse)} fail differently")
    for x in r["regressions"]:
        print(f"  REGRESSION {x['case']}: {x['base']} -> {x['new']} {x['msg']}")
    for x in r["fixes"]:
        print(f"  fixed {x['case']}: {x['base']} -> {x['new']}")
json.dump(report, open(f"{new}/compare.json", "w"), indent=1)
