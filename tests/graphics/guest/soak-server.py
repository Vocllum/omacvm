#!/usr/bin/env python3
"""Guest side of soak.sh: serves webgl.html, appends the page's frame counts to frames.txt."""
import http.server, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open("frames.txt", "a") as f:
            f.write(self.rfile.read(n).decode().strip() + "\n")
        self.send_response(204); self.end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", 8766), H).serve_forever()
