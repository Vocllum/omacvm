"""The control centre's moving parts in one place, for the TUI and the plain
text output: local files, the Mac's answers, the VM's checks, jobs, updates.
Methods that talk to the Mac or run checks block: the TUI calls them from
worker threads."""
from __future__ import annotations

import time

from . import state as S
from .bridge import Bridge, BridgeError, Hello
from .local import Local, guest_checks

ACTION_FOR = {True: "enable", False: "disable"}


class Controller:
    def __init__(self) -> None:
        self.local = Local()
        self.bridge = Bridge(self.local.env, self.local.version)
        self.hello: Hello | None = None
        self.mac_error: BridgeError | None = None
        c = self.local.cache
        self.mac_status: dict | None = c.get("mac_status") if isinstance(c.get("mac_status"), dict) else None
        self.vm_checks: list[S.Check] | None = None
        if isinstance(c.get("vm_checks"), str):
            self.vm_checks = S.parse_check_tsv(c["vm_checks"])
        self.checked_at: float | None = c.get("checked_at") if isinstance(c.get("checked_at"), (int, float)) else None
        self.from_cache = self.vm_checks is not None or self.mac_status is not None
        self.updates: dict | None = c.get("updates") if isinstance(c.get("updates"), dict) else None
        self.jobs: dict[str, S.Job] = {}
        self.job_lines: dict[str, list[str]] = {}

    # ---- the Mac ----
    @property
    def linked(self) -> bool:
        """The Mac answers and takes requests from this VM."""
        return self.hello is not None and self.mac_error is None

    def mac_problem(self) -> str:
        """Why switching from here does not work right now ("" if it does)."""
        if self.local.vm_type == "app":
            return "OmacVM.app's VMs switch features with omacvm on the Mac for now"
        if self.mac_error is not None:
            return str(self.mac_error)
        if self.hello is None:
            return "asking the Mac"
        return ""

    def refresh_mac(self) -> None:
        try:
            self.hello = self.bridge.hello()
            self.mac_error = None
        except BridgeError as e:
            self.hello, self.mac_error = None, e
            return
        try:
            st = self.bridge.status()
            if not st.get("pending"):
                self.mac_status = st
                self.local.save_cache(mac_status=st)
        except BridgeError as e:
            self.mac_error = e

    def refresh_updates(self, check: bool = False) -> dict | None:
        try:
            self.updates = self.bridge.check_updates() if check else self.bridge.updates()
            self.local.save_cache(updates=self.updates)
        except BridgeError as e:
            if check:
                raise
            self.mac_error = self.mac_error or e
        return self.updates

    def set_update_checks(self, on: bool) -> None:
        self.updates = self.bridge.set_update_checks(on)
        self.local.save_cache(updates=self.updates)

    # ---- the VM ----
    def refresh_vm_checks(self) -> None:
        checks = guest_checks()
        if checks is not None:
            self.vm_checks = checks
            self.checked_at = time.time()
            self.from_cache = False
            self.local.save_cache(vm_checks="\n".join(
                f"{c.status}\t{c.name}\t{c.detail}\t{'1' if c.human else ''}\t{c.feature}" for c in checks),
                checked_at=self.checked_at)

    def reload_local(self) -> None:
        """After a job: the VM's env and installed parts changed."""
        cache = self.local.cache
        self.local = Local()
        self.local.cache = cache
        self.bridge = Bridge(self.local.env, self.local.version)

    # ---- the model ----
    def offer(self) -> dict:
        m = (self.updates or {}).get("manifest")
        parts = m.get("parts") if isinstance(m, dict) else None
        return parts if isinstance(parts, dict) else {}

    def rows(self) -> list[S.Row]:
        avail = {}
        mac_checks = None
        if self.mac_status:
            for f in self.mac_status.get("features") or []:
                if isinstance(f, dict) and f.get("name"):
                    avail[f["name"]] = S.Avail(bool(f.get("available", True)), str(f.get("reason") or ""))
            if isinstance(self.mac_status.get("checks"), list):
                mac_checks = S.parse_mac_checks(self.mac_status["checks"])
        checks = None if self.vm_checks is None and mac_checks is None else (self.vm_checks or []) + (mac_checks or [])
        mac_features = set(self.hello.features) if self.hello and self.hello.features else None
        return S.build_rows(self.local.features, self.local.on, vm_type=self.local.vm_type, avail=avail,
                            checks=checks, jobs=list(self.jobs.values()), installed=self.local.installed_parts(),
                            offer=self.offer(), mac_features=mac_features)

    # ---- jobs ----
    def _job(self, d: dict) -> S.Job:
        j = S.Job(id=str(d.get("id", "")), action=str(d.get("action", "")),
                  features=tuple(str(x) for x in d.get("features") or ()), state=str(d.get("state", "running")),
                  step=int(d.get("step") or 0), of=int(d.get("of") or 0), text=str(d.get("text", "")))
        self.jobs[j.id] = j
        self.job_lines[j.id] = [str(x) for x in d.get("lines") or []]
        return j

    def start(self, action: str, features: list[str] | tuple[str, ...] = ()) -> S.Job:
        return self._job(self.bridge.start_job(action, list(features)))

    def poll(self, job_id: str) -> S.Job:
        return self._job(self.bridge.job(job_id))

    def active_job(self) -> S.Job | None:
        return next((j for j in self.jobs.values() if j.active), None)
