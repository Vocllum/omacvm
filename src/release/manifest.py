#!/usr/bin/env python3
"""Update manifests (docs/adr/0032): one digest per part of src/.

  manifest.py digests [--src DIR]
      {"version", "parts": {part: {"digest", "release"}}} for this copy of
      src/ (omacvm apply writes it to the VM's /etc/omacvm/installed.json)
  manifest.py build --version V --commit C [--previous FILE] [--date D] [--notes FILE] [--src DIR]
      the release manifest; a part keeps the release of the previous manifest
      while its digest is the same, so nobody bumps versions by hand. --notes:
      "part<TAB>note" lines (one line per changed part)
  manifest.py parts [--src DIR]
      every file with its part (to check parts.tsv)

A digest is sha256 over the part's files, sorted: "path<TAB>sha256 of the
file" lines. build/ and __pycache__/ are left out (apply does not copy them).
Sign the result with sign.swift. Runs with macOS's python3 3.9.
"""
from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = {"build", "__pycache__", ".pytest_cache"}


def load_parts(path: str) -> list:
    parts = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            name, _, pats = line.rstrip("\n").partition("\t")
            parts.append((name, pats.split()))
    return parts


def match(path: str, pat: str) -> bool:
    if pat == "**":
        return True
    if pat.endswith("/**"):
        return path.startswith(pat[:-2])
    return fnmatch.fnmatchcase(path, pat) and path.count("/") == pat.count("/")


def files(src: str) -> list:
    out = []
    for root, dirs, names in os.walk(src):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for n in names:
            if n == ".DS_Store":
                continue
            out.append(os.path.relpath(os.path.join(root, n), src).replace(os.sep, "/"))
    return sorted(out)


def assign(src: str, parts: list) -> dict:
    by: dict = {name: [] for name, _ in parts}
    for f in files(src):
        for name, pats in parts:
            if any(match(f, p) for p in pats):
                by[name].append(f)
                break
    return by


def digests(src: str) -> dict:
    out = {}
    for name, fs in assign(src, load_parts(os.path.join(HERE, "parts.tsv"))).items():
        h = hashlib.sha256()
        for f in fs:
            with open(os.path.join(src, f), "rb") as fh:
                h.update(f"{f}\t{hashlib.sha256(fh.read()).hexdigest()}\n".encode())
        out[name] = "sha256:" + h.hexdigest()
    return out


def version(src: str) -> str:
    with open(os.path.join(src, "VERSION"), encoding="utf-8") as f:
        return f.read().strip()


def main() -> int:
    ap = argparse.ArgumentParser(prog="manifest.py")
    ap.add_argument("cmd", choices=["digests", "build", "parts"])
    ap.add_argument("--src", default=os.path.dirname(HERE))
    ap.add_argument("--version")
    ap.add_argument("--commit")
    ap.add_argument("--previous")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--notes")
    a = ap.parse_args()
    if a.cmd == "parts":
        for name, fs in assign(a.src, load_parts(os.path.join(HERE, "parts.tsv"))).items():
            for f in fs:
                print(f"{name}\t{f}")
        return 0
    d = digests(a.src)
    if a.cmd == "digests":
        v = version(a.src)
        json.dump({"version": v, "parts": {k: {"digest": x, "release": v} for k, x in sorted(d.items())}}, sys.stdout)
        print()
        return 0
    if not (a.version and re.match(r"^\d+\.\d+\.\d+$", a.version)):
        ap.error("--version X.Y.Z")
    if not (a.commit and re.match(r"^[0-9a-f]{40}$", a.commit)):
        ap.error("--commit: the release commit, 40 hex digits")
    prev = {}
    if a.previous:
        with open(a.previous, encoding="utf-8") as f:
            prev = json.load(f).get("parts", {})
    notes = {}
    if a.notes:
        with open(a.notes, encoding="utf-8") as f:
            for line in f:
                k, _, n = line.rstrip("\n").partition("\t")
                if n:
                    notes[k] = n[:120]
    parts = {}
    for k, x in sorted(d.items()):
        same = prev.get(k, {}).get("digest") == x
        p = {"digest": x, "release": prev[k]["release"] if same else a.version}
        if not same and k in notes:
            p["note"] = notes[k]
        parts[k] = p
    m = {"schema": 1, "version": a.version, "commit": a.commit, "date": a.date, "channel": "stable",
         "notes_url": f"https://github.com/gillesgoetsch/omacvm/releases/tag/v{a.version}",
         "proto": 1, "proto_min": 1, "parts": parts}
    json.dump(m, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
