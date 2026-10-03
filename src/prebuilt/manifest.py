#!/usr/bin/env python3
"""Prebuilt image manifests.

  manifest.py write OUT.json --route R --omacvm V --omarchy V --bundle NAME
                    --unpacked KB --disk-gb N PART...
  manifest.py get MANIFEST KEY             one value (route, omacvm, omarchy, bundle,
                                           size, unpacked_kb, disk_gb, created)
  manifest.py parts MANIFEST               one line per part: NAME SIZE SHA256
  manifest.py release RELEASES.json VERSION ROUTE
                                           from GitHub's release list: the tag and the
                                           manifest's URL for this version and route
                                           (exact tag prebuilt-VERSION first, else the
                                           newest prebuilt-VERSION-*)
  manifest.py asset RELEASES.json TAG NAME the download URL of one asset
"""
import datetime
import hashlib
import json
import os
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write(a):
    out, rest = a[0], a[1:]
    opts, parts = {}, []
    i = 0
    while i < len(rest):
        if rest[i].startswith("--"):
            opts[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            parts.append(rest[i])
            i += 1
    m = {
        "format": 1,
        "route": opts["route"],
        "omacvm": opts["omacvm"],
        "omarchy": opts["omarchy"],
        "bundle": opts["bundle"],
        "unpacked_kb": int(opts["unpacked"]),
        "disk_gb": int(opts["disk-gb"]),
        "compression": "tar + zstd --long=27",
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "parts": [{"name": os.path.basename(p), "size": os.path.getsize(p), "sha256": sha256(p)} for p in sorted(parts)],
    }
    m["size"] = sum(p["size"] for p in m["parts"])
    json.dump(m, open(out, "w"), indent=2)
    print(out)


def main(a):
    if len(a) < 2:
        sys.exit(__doc__)
    cmd = a[1]
    if cmd == "write":
        write(a[2:])
    elif cmd == "get":
        v = json.load(open(a[2])).get(a[3], "")
        print(v)
    elif cmd == "parts":
        for p in json.load(open(a[2]))["parts"]:
            print(p["name"], p["size"], p["sha256"])
    elif cmd == "release":
        rels, version, route = json.load(open(a[2])), a[3], a[4]
        want = "omacvm-prebuilt-%s-%s.json" % (version, route)
        cands = []
        for r in rels:
            t = r.get("tag_name", "")
            if r.get("draft") or not (t == "prebuilt-" + version or t.startswith("prebuilt-%s-" % version)):
                continue
            for x in r.get("assets", []):
                if x["name"] == want:
                    cands.append((t == "prebuilt-" + version, r.get("published_at") or "", t, x["browser_download_url"]))
        if not cands:
            sys.exit(1)
        best = max(cands)   # the exact tag first, then the newest
        print(best[2], best[3])
    elif cmd == "asset":
        for r in json.load(open(a[2])):
            if r.get("tag_name") == a[3]:
                for x in r.get("assets", []):
                    if x["name"] == a[4]:
                        print(x["browser_download_url"])
                        return
        sys.exit(1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
