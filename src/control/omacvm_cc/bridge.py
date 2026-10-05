"""Client for the Mac's side of the control centre: the OmacVM Bridge's
/omacvm/* requests (docs/adr/0031). Same rules as omacvm-bridge (the shell
client): the token goes only to a Bridge that first proved it knows it. Each
request also carries this VM's own key (~/.config/omacvm-bridge/vm-key, from
omacvm apply), so a VM that takes another VM's address cannot act for it.

OmacVM.app's VMs ask through the app instead: the virtio-serial port
org.omacvm.control, one JSON line per request and per answer. The app knows
which VM's port it is and passes the request on to the Bridge.

Every call raises BridgeError with a kind the UI can show:
  offline  the Mac does not answer (VM network down, Bridge not running)
  unproven something answered but did not prove it is OmacVM's Bridge
  old      the Mac's OmacVM has no control centre requests yet (404 on hello)
  refused  the Mac said no (busy, rate limit, update first, not this VM ...)
"""
from __future__ import annotations

import hashlib
import hmac
import http.client
import json
import os
import secrets
import errno
import select
import threading
import time
from dataclasses import dataclass
from urllib.parse import urlsplit

PROTO = 1          # what this client speaks
PORT = 47831
CONTROL_PORT = "/dev/virtio-ports/org.omacvm.control"
ANSWER_MAX = 1 << 20


class BridgeError(Exception):
    def __init__(self, kind: str, message: str, status: int = 0, code: str = ""):
        super().__init__(message)
        self.kind, self.status, self.code = kind, status, code


@dataclass(frozen=True)
class Hello:
    proto: int
    omacvm: str
    requests: tuple[str, ...]
    features: tuple[str, ...]
    macos: str = ""
    chip: str = ""


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


class Bridge:
    def __init__(self, env: dict[str, str], vm_version: str, token_file: str | None = None,
                 url: str | None = None):
        host = env.get("OMACVM_HOST") or "10.211.55.2"
        self.url = (url or os.environ.get("OMACVM_BRIDGE_URL") or f"http://{host}:{PORT}").rstrip("/")
        parts = urlsplit(self.url)
        self.host, self.port = parts.hostname or host, parts.port or PORT
        # OmacVM.app: the VM's 10.0.2.2 is the Mac's 127.0.0.1 (as in omacvm-bridge).
        self.mac_addr = "127.0.0.1" if env.get("OMACVM_VM_TYPE") == "app" else self.host
        self.token_file = token_file or os.environ.get("OMACVM_BRIDGE_TOKEN_FILE") or \
            os.path.expanduser("~/.config/omacvm-bridge/token")
        self.vm_key_file = os.environ.get("OMACVM_VM_KEY_FILE") or os.path.expanduser("~/.config/omacvm-bridge/vm-key")
        self.vm_version = vm_version
        self.proto = PROTO
        self._proven_at = 0.0
        # OmacVM.app: its control port (OMACVM_CONTROL_PORT for tests).
        port = os.environ.get("OMACVM_CONTROL_PORT") or CONTROL_PORT
        direct = url or os.environ.get("OMACVM_BRIDGE_URL")
        self.port_path = port if env.get("OMACVM_VM_TYPE") == "app" and not direct and os.path.exists(port) else ""
        self._port_lock = threading.Lock()

    # ---- transport ----
    def _token(self) -> bytes:
        try:
            with open(self.token_file, "rb") as f:
                return f.read().strip()
        except OSError as e:
            raise BridgeError("unproven", f"no Bridge token in this VM ({e.strerror}): omacvm apply on the Mac") from e

    def _raw(self, method: str, path: str, body: bytes | None, headers: dict, timeout: float):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            data = r.read(1 << 20)
            return r.status, data
        except (OSError, http.client.HTTPException) as e:
            raise BridgeError("offline", f"the Mac does not answer at {self.host}:{self.port} ({e})") from e
        finally:
            conn.close()

    def prove(self, timeout: float = 3.0) -> None:
        """GET /proof: HMAC-SHA256(token, "omacvm-bridge mac <addr> <nonce>")."""
        if time.monotonic() - self._proven_at < 60:
            return
        token = self._token()
        nonce = secrets.token_hex(16)
        status, data = self._raw("GET", f"/proof?nonce={nonce}", None, {}, timeout)
        try:
            got = json.loads(data).get("proof", "")
        except (ValueError, AttributeError):
            got = ""
        want = hmac.new(token, f"omacvm-bridge mac {self.mac_addr} {nonce}".encode(), hashlib.sha256).hexdigest()
        if status != 200 or not isinstance(got, str) or not hmac.compare_digest(want, got):
            raise BridgeError("unproven", f"{self.host}:{self.port} did not prove it is OmacVM's Bridge; token not sent")
        self._proven_at = time.monotonic()

    def _vm_key(self) -> str:
        try:
            with open(self.vm_key_file, encoding="ascii") as f:
                return f.read().strip()
        except (OSError, ValueError):
            return ""

    def _port(self, method: str, path: str, obj: dict | None, timeout: float) -> tuple[int, dict]:
        """One request over OmacVM.app's control port. The port opens for one
        program at a time (the notice timer may have it a moment): retried."""
        rid = secrets.token_hex(8)
        line = json.dumps({"id": rid, "method": method, "path": path, "body": obj, "proto": self.proto,
                           "version": self.vm_version}).encode() + b"\n"
        end = time.monotonic() + timeout
        with self._port_lock:
            while True:
                try:
                    fd = os.open(self.port_path, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
                    break
                except OSError as e:
                    if e.errno != errno.EBUSY or time.monotonic() > end:
                        raise BridgeError("offline", f"OmacVM.app's control port: {e.strerror}") from e
                    time.sleep(0.1)
            try:
                sent = 0
                while sent < len(line):
                    left = end - time.monotonic()
                    if left <= 0 or not select.select([], [fd], [], left)[1]:
                        raise BridgeError("offline", "OmacVM.app does not read this VM's control port (update OmacVM.app)")
                    sent += os.write(fd, line[sent:])
                buf = b""
                while True:
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        try:
                            a = json.loads(raw)
                        except ValueError:
                            continue
                        if isinstance(a, dict) and a.get("id") == rid:   # an earlier, given-up answer is skipped
                            body = a.get("body")
                            return int(a.get("status") or 0), body if isinstance(body, dict) else {}
                    left = end - time.monotonic()
                    if left <= 0 or not select.select([fd], [], [], left)[0]:
                        raise BridgeError("offline", "OmacVM.app did not answer on this VM's control port")
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        time.sleep(0.05)   # the app is not connected yet
                        continue
                    buf += chunk
                    if len(buf) > ANSWER_MAX:
                        raise BridgeError("offline", "OmacVM.app's answer was too long")
            except OSError as e:
                raise BridgeError("offline", f"OmacVM.app's control port: {e.strerror}") from e
            finally:
                os.close(fd)

    def call(self, method: str, path: str, obj: dict | None = None, timeout: float = 5.0) -> dict:
        if self.port_path and path.startswith("/omacvm/"):
            status, answer = self._port(method, path, obj, timeout)
            if status == 0:   # the app could not reach the Bridge
                raise BridgeError("offline", str(answer.get("error") or "OmacVM Bridge does not answer on the Mac"))
        else:
            self.prove(min(timeout, 3.0))
            body = None if obj is None else json.dumps(obj).encode()
            headers = {"Authorization": "Bearer " + self._token().decode("ascii", "replace"),
                       "X-OmacVM-Proto": str(self.proto), "X-OmacVM-Version": self.vm_version}
            key = self._vm_key() if path.startswith("/omacvm/") else ""
            if key:
                headers["X-OmacVM-VM-Key"] = key
            if body is not None:
                headers["Content-Type"] = "application/json"
            status, data = self._raw(method, path, body, headers, timeout)
            try:
                answer = json.loads(data) if data.strip() else {}
            except ValueError:
                answer = {}
            if not isinstance(answer, dict):
                answer = {}
        if status == 200 or status == 202:
            return answer
        msg = str(answer.get("error") or f"HTTP {status}")
        if status == 404 and path.startswith("/omacvm/hello"):
            raise BridgeError("old", "the Mac's OmacVM has no control centre yet: run omacvm update on the Mac", status)
        if status == 401:
            raise BridgeError("unproven", "the Mac refused this VM's token: omacvm apply on the Mac", status)
        raise BridgeError("refused", msg, status, str(answer.get("code", "")))

    # ---- requests (the fixed list) ----
    def hello(self) -> Hello:
        a = self.call("GET", "/omacvm/hello", timeout=3.0)
        proto = int(a.get("proto", 0) or 0)
        if proto < 1:
            raise BridgeError("old", "the Mac speaks no control centre protocol this VM knows")
        self.proto = min(PROTO, proto)
        return Hello(proto=self.proto, omacvm=str(a.get("omacvm", "")),
                     requests=tuple(str(x) for x in a.get("requests", [])),
                     features=tuple(str(x) for x in a.get("features", [])),
                     macos=str(a.get("macos", "")), chip=str(a.get("chip", "")))

    def status(self) -> dict:
        return self.call("GET", "/omacvm/status", timeout=60.0)

    def updates(self) -> dict:
        return self.call("GET", "/omacvm/updates", timeout=5.0)

    def check_updates(self) -> dict:
        return self.call("POST", "/omacvm/updates/check", {}, timeout=30.0)

    def set_update_checks(self, enabled: bool) -> dict:
        return self.call("POST", "/omacvm/settings/update-checks", {"enabled": bool(enabled)})

    def start_job(self, action: str, features: list[str] | tuple[str, ...] = ()) -> dict:
        body: dict = {"action": action}
        if action != "update":
            body["features"] = list(features)
        return self.call("POST", "/omacvm/jobs", body, timeout=10.0)

    def job(self, job_id: str) -> dict:
        if not job_id.isalnum():
            raise BridgeError("refused", "bad job id")
        return self.call("GET", f"/omacvm/jobs/{job_id}", timeout=5.0)
