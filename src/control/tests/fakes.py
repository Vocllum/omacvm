"""A fake Mac for the control centre's tests: the Bridge's /proof and
/omacvm/* requests, and the VM's check socket. Same answers as the real ones
(src/bridge/mac/control.swift, guest/check.sh --tsv)."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import socket
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SRC = os.path.join(os.path.dirname(__file__), "..", "..")

CHECKS_TSV = (
    "section\tThe Mac in the bar (Bridge)\n"
    "ok\tWi-Fi\tZorroNet 5G, -48 dBm\t\tbridge\n"
    "ok\tgestures\tconnected to the Mac\t\tgestures\n"
    "fail\taudio\tno answer from the Bridge\t\tcamera\n"
    "ok\tzram swap\t4G\t\t\n"
)


class FakeMac:
    def __init__(self, old: bool = False, version: str = "2.7.0") -> None:
        self.old, self.version = old, version
        self.job_end = ("done", "done")   # (state, text) a job ends with
        self.requests: list[tuple[str, str, dict]] = []
        self.jobs: dict[str, dict] = {}
        self.checks_enabled = True
        self.manifest: dict | None = None
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def send(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}") if n else {}

            def do_GET(self):
                p = self.path
                if p.startswith("/proof?nonce="):
                    n = p.split("=", 1)[1]
                    return self.send(200, {"proof": hmac.new(TOKEN, f"omacvm-bridge mac 127.0.0.1 {n}".encode(),
                                                             hashlib.sha256).hexdigest()})
                if self.headers.get("Authorization") != "Bearer " + TOKEN.decode():
                    return self.send(401, {"error": "token"})
                fake.requests.append(("GET", p, {}))
                if fake.old and p.startswith("/omacvm/"):
                    return self.send(404, {"error": "not found"})
                if p == "/omacvm/hello":
                    names = [l.split("\t")[0] for l in open(os.path.join(SRC, "features.tsv"), encoding="utf-8")
                             if l.strip() and not l.startswith("#")]
                    return self.send(200, {"proto": 1, "proto_min": 1, "omacvm": fake.version, "features": names,
                                           "requests": ["hello", "status", "updates", "jobs"], "macos": "15.7.4",
                                           "chip": "Apple M4 Max"})
                if p == "/omacvm/status":
                    return self.send(200, {"omacvm": fake.version, "features": [
                        {"name": "omanotch", "on": False, "available": False, "reason": "needs a MacBook with a notch"}],
                        "checks": [{"status": "fail", "name": "keyboard/trackpad access", "detail":
                                    "waiting for Accessibility: System Settings > Privacy & Security", "needs_human": True,
                                    "feature": "gestures"}]})
                if p == "/omacvm/updates":
                    return self.send(200, fake.updates())
                if p.startswith("/omacvm/jobs/"):
                    j = fake.jobs.get(p.rsplit("/", 1)[1])
                    if not j:
                        return self.send(404, {"error": "no such job"})
                    j["polls"] += 1
                    if j["polls"] >= 2:
                        j["state"], j["text"] = fake.job_end
                    return self.send(200, {k: v for k, v in j.items() if k != "polls"})
                if p in ("/state", "/scan?cached=1", "/bluetooth"):
                    return self.send(200, {"ssid": "ZorroNet 5G", "bssid": "a4:2b:b0:11:22:33",
                                           "networks": [{"ssid": "Zorro Guest"}],
                                           "devices": [{"name": "Zorro's AirPods", "address": "11:22:33:44:55:66"}]})
                self.send(404, {"error": "not found"})

            def do_POST(self):
                if self.headers.get("Authorization") != "Bearer " + TOKEN.decode():
                    return self.send(401, {"error": "token"})
                b = self.body()
                fake.requests.append(("POST", self.path, b))
                if self.path == "/omacvm/jobs":
                    jid = f"{len(fake.jobs) + 1:016x}"
                    fake.jobs[jid] = {"id": jid, "action": b["action"], "features": b.get("features", []),
                                      "state": "running", "step": 1, "of": 0, "text": "OmacVM Bridge on the Mac",
                                      "lines": ["==> OmacVM Bridge on the Mac"], "polls": 0}
                    return self.send(202, {k: v for k, v in fake.jobs[jid].items() if k != "polls"})
                if self.path == "/omacvm/settings/update-checks":
                    fake.checks_enabled = bool(b["enabled"])
                    return self.send(200, fake.updates())
                if self.path == "/omacvm/updates/check":
                    return self.send(200, fake.updates())
                self.send(404, {"error": "not found"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def updates(self) -> dict:
        return {"checks_enabled": self.checks_enabled, "omacvm": self.version, "checked_at": "2026-10-05T10:41:00Z",
                "ok": self.manifest is not None, "offline": False, "error": None, "manifest": self.manifest}

    def stop(self) -> None:
        self.server.shutdown()


class FakeChecks:
    """/run/omacvm/check.sock: answers guest/check.sh --tsv lines and closes."""

    def __init__(self, tsv: str = CHECKS_TSV) -> None:
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "check.sock")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.path)
        self.sock.listen(4)
        self.tsv = tsv

        def serve():
            while True:
                try:
                    c, _ = self.sock.accept()
                except OSError:
                    return
                c.sendall(self.tsv.encode())
                c.close()
        threading.Thread(target=serve, daemon=True).start()

    def stop(self) -> None:
        self.sock.close()


def vm_env(tmp: str, mac_port: int, check_sock: str, extra: str = "") -> dict:
    """Environment variables pointing the control centre at the fakes."""
    env_file = os.path.join(tmp, "env")
    with open(env_file, "w") as f:
        f.write("OMACVM_VM_TYPE=parallels\nOMACVM_HOST=127.0.0.1\nOMACVM_USER=zorro\n"
                "OMACVM_FEATURE_bridge=on\nOMACVM_FEATURE_wallpaper=on\nOMACVM_FEATURE_gestures=off\n"
                "OMACVM_FEATURE_scroll_momentum=off\nOMACVM_FEATURE_omanotch=off\nOMACVM_FEATURE_mac_clock=on\n"
                "OMACVM_FEATURE_camera=on\nOMACVM_FEATURE_battery=off\nOMACVM_FEATURE_idle_lock=on\n"
                "OMACVM_FEATURE_autologin=off\nOMACVM_FEATURE_thp_kernel=off\nOMACVM_FEATURE_control_centre=on\n" + extra)
    token = os.path.join(tmp, "token")
    with open(token, "wb") as f:
        f.write(TOKEN + b"\n")
    installed = os.path.join(tmp, "installed.json")
    with open(installed, "w") as f:
        json.dump({"version": "2.7.0", "parts": {"gestures": {"digest": "sha256:" + "a" * 64, "release": "2.7.0"},
                                                 "bridge": {"digest": "sha256:" + "b" * 64, "release": "2.7.0"}}}, f)
    return {"OMACVM_SHARE": os.path.abspath(SRC), "OMACVM_ENV": env_file, "OMACVM_INSTALLED": installed,
            "OMACVM_CHECK_SOCKET": check_sock, "OMACVM_BRIDGE_URL": f"http://127.0.0.1:{mac_port}",
            "OMACVM_BRIDGE_TOKEN_FILE": token, "XDG_CACHE_HOME": os.path.join(tmp, "cache")}
