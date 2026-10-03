#!/usr/bin/env python3
"""Prebuilt image manifests.

  manifest.py write OUT.json --route R --omacvm V --omarchy V --bundle NAME
                    --unpacked KB --disk-gb N PART...
  manifest.py get MANIFEST KEY             one value (route, omacvm, omarchy, bundle,
                                           size, unpacked_kb, disk_gb, created)
  manifest.py parts MANIFEST               one line per part: NAME SIZE SHA256
  manifest.py release RELEASES.json VERSION ROUTE
                                           from GitHub's release list: TAG URL IMAGE_VERSION
                                           of the newest image for ROUTE with the same
                                           major version, up to VERSION
  manifest.py local DIR VERSION ROUTE      the same from a folder: NAME IMAGE_VERSION
  manifest.py asset RELEASES.json TAG NAME the download URL of one asset
"""
import datetime
import hashlib
import json
import os
import re
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


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def pick(cands, version, route):
    """cands: (tag, published, asset name, url) -> (VERSION, cand) of the best."""
    want = re.compile(r"^omacvm-prebuilt-(\d+\.\d+\.\d+)-%s\.json$" % re.escape(route))
    mine = vtuple(version)
    best = None
    for c in cands:
        m = want.match(c[2])
        if not m:
            continue
        v = vtuple(m.group(1))
        if v[0] != mine[0] or v > mine:
            continue
        key = (v, c[1])
        if best is None or key > best[0]:
            best = (key, c)
    return (".".join(map(str, best[0][0])), best[1]) if best else None


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
        # The newest image for this route with the same major version and a
        # version up to ours (the first omacvm apply brings the guest side
        # to ours): prints TAG URL VERSION.
        rels, version, route = json.load(open(a[2])), a[3], a[4]
        best = pick([(r.get("tag_name", ""), r.get("published_at") or "", x["name"], x["browser_download_url"])
                     for r in rels if not r.get("draft") and r.get("tag_name", "").startswith("prebuilt-")
                     for x in r.get("assets", [])], version, route)
        if not best:
            sys.exit(1)
        print(best[1][0], best[1][3], best[0])
    elif cmd == "local":
        # the same from a folder of files: prints NAME VERSION
        names = [(None, "", n, None) for n in os.listdir(a[2])]
        best = pick(names, a[3], a[4])
        if not best:
            sys.exit(1)
        print(best[1][2], best[0])
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
