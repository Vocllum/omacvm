#!/usr/bin/env python3
"""Guest side: serve the Khronos WebGL conformance suite plus our runner page.
GET /list.json -> test pages for the chosen WebGL version and filter;
POST /result and /done -> appended to OUT as JSON lines.
Usage: webgl-server.py SUITE_DIR RUNNER_HTML OUT.jsonl VERSION FILTER_REGEX [PORT]"""
import http.server, json, os, re, sys

suite, runner, out, version, filt = sys.argv[1:6]
port = int(sys.argv[6]) if len(sys.argv) > 6 else 8765
want = tuple(int(x) for x in version.split("."))


def ver(s):
    return tuple(int(x) for x in s.split("."))


def tests(listfile, base=""):
    """Walk 00_test_list.txt files like the official harness (min/max version options)."""
    found = []
    for line in open(os.path.join(suite, base, listfile)):
        line = line.strip()
        if line.startswith("//") or line.startswith("#"):
            continue
        parts = line.split()
        if not parts:
            continue
        name, opts = parts[-1], parts[:-1]
        ok = True
        for i, o in enumerate(opts):
            if o == "--min-version" and want < ver(opts[i + 1]):
                ok = False
            if o == "--max-version" and want > ver(opts[i + 1]):
                ok = False
            if o == "--slow":
                pass
        if not ok:
            continue
        path = os.path.normpath(os.path.join(base, name))
        if name.endswith(".txt"):
            found += tests(os.path.basename(path), os.path.dirname(path))
        elif re.search(filt, path):
            found.append(path)
    return found


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=suite, **k)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/list.json":
            body = json.dumps(tests("00_test_list.txt")).encode()
        elif self.path.startswith("/omacvm-runner.html"):
            body = open(runner, "rb").read()
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        rec = json.loads(self.rfile.read(n) or b"{}")
        rec["kind"] = self.path.strip("/")
        with open(out, "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(204)
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
