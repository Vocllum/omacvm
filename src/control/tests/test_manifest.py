"""The release manifest says what it is: "kind": "control-manifest" (one key
signs it and OmacVM.app's feed, "app-feed"; the Bridge refuses any other
kind, src/bridge/mac/tests/control_tests.swift)."""
import json
import os
import subprocess
import sys

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_build_writes_the_kind():
    out = subprocess.run([sys.executable, os.path.join(SRC, "release", "manifest.py"), "build", "--version", "2.9.1",
                          "--commit", "a" * 40, "--date", "2026-10-20"], capture_output=True, text=True, check=True).stdout
    m = json.loads(out)
    assert m["schema"] == 1 and m["kind"] == "control-manifest" and m["version"] == "2.9.1"
    assert "core" in m["parts"] and all(p["digest"].startswith("sha256:") for p in m["parts"].values())
