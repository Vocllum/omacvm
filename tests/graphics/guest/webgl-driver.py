#!/usr/bin/env python3
"""Guest side of webgl.sh, run as the desktop user in the Hyprland session: starts Chrome on
the runner page and restarts it when needed, until the runner posts "done".
- isolate: the runner stops after a failing page; Chrome is restarted and the page tried once
  more in a fresh GPU process (on virgl one failed host shader compile puts the whole guest
  context in error, so every later page of that Chrome would fail too). Then the next page.
- a page that posts nothing for STALL s (renderer blocked in a GL call) is recorded as "hang"
  and Chrome restarted at the next page.
Usage: webgl-driver.py OUT.jsonl WEBGL_MAJOR ISOLATE STALL_S [FIRST_PAGE]"""
import json, os, subprocess, sys, time, urllib.request

out, wv, isolate, stall = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
first_page = int(sys.argv[5]) if len(sys.argv) > 5 else 0
PROF = "/tmp/webgl-prof"
chrome = None


def start(index, attempt):
    global chrome
    subprocess.run(["pkill", "-9", "-f", PROF])
    time.sleep(1)
    url = f"http://127.0.0.1:8765/omacvm-runner.html?v={wv}&start={index}&attempt={attempt}&isolate={isolate}"
    log = open("/tmp/webgl-chrome.log", "a")
    chrome = subprocess.Popen(["google-chrome-stable", f"--user-data-dir={PROF}", "--no-first-run",
                               "--no-default-browser-check", "--ozone-platform=wayland",
                               "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                               "--hide-crash-restore-bubble", url], stdout=log, stderr=log)


def post(path, rec):
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8765" + path, json.dumps(rec).encode(),
                                                  method="POST"), timeout=10)


# records already in OUT (a run resumed after a VM restart) are not ours to act on
pos = os.path.getsize(out) if os.path.exists(out) else 0
start(first_page, 1)
cur, seen_at, restarts = None, time.time(), 0
while True:
    time.sleep(0.5)
    with open(out) if os.path.exists(out) else open(os.devnull) as f:
        f.seek(pos)
        lines = f.readlines()
        pos = f.tell()
    for l in lines:
        r = json.loads(l)
        seen_at = time.time()
        if r["kind"] == "begin":
            cur = r
        elif r["kind"] == "stop":
            restarts += 1
            start(r["index"], 2) if r["attempt"] == 1 else start(r["index"] + 1, 1)
        elif r["kind"] == "done":
            subprocess.run(["pkill", "-9", "-f", PROF])
            sys.exit(0)
    if cur and time.time() - seen_at > stall:
        post("/result", {"test": cur["test"], "index": cur["index"], "attempt": cur["attempt"], "status": "hang",
                         "pass": 0, "fail": 1, "skip": 0, "ms": stall * 1000,
                         "msgs": [f"no result for {stall} s, Chrome restarted"]})
        start(cur["index"] + 1, 1)
        seen_at = time.time()
