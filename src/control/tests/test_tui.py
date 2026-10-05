"""The control centre in Textual's headless driver (Pilot), against a fake
Mac: first frame time, keys, jobs, offline and older-Mac banners, updates,
report. Skipped where Textual is not installed."""
import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

textual = pytest.importorskip("textual")

from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402


@pytest.fixture
def world(tmp_path, monkeypatch):
    mac, checks = FakeMac(), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path).items():
        monkeypatch.setenv(k, v)
    yield mac
    mac.stop()
    checks.stop()


def app():
    from omacvm_cc.controller import Controller
    from omacvm_cc.tui import ControlCentre
    return ControlCentre(Controller())


async def settle(pilot, until, seconds=8.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        await pilot.pause(0.05)
        if until():
            return True
    a = pilot.app
    print("settle timed out:", a.c.hello, a.c.mac_error, a.c.vm_checks is not None, [w.name for w in a.workers])
    return False


def rows(a):
    return {r.feature.name: r for r in a.rows}


def test_first_frame_fast(world):
    async def go():
        t0 = time.monotonic()
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            await pilot.pause()
            first = time.monotonic() - t0
            assert first < 0.5, f"first frame after {first:.2f} s"
            from textual.widgets import DataTable
            assert a.screen.query_one(DataTable).row_count == len(a.rows) >= 12
    asyncio.run(go())


def test_statuses_fill_in(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            await pilot.pause(0.2)
            r = rows(a)
            from omacvm_cc.state import Status
            assert r["bridge"].status is Status.WORKS
            assert r["camera"].status is Status.FAILING
            assert r["omanotch"].status is Status.UNAVAILABLE and "notch" in r["omanotch"].note
            assert r["gestures"].status is Status.OFF
            assert "Mac linked" in a.subtitle()
    asyncio.run(go())


def test_space_switches_through_the_mac(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            t = a.screen.query_one(DataTable)
            t.move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            posts = [b for m, p, b in world.requests if p == "/omacvm/jobs"]
            assert posts[-1] == {"action": "enable", "features": ["autologin"]}
            assert await settle(pilot, lambda: all(not j.active for j in a.c.jobs.values()) and a.c.jobs)
    asyncio.run(go())


def test_failed_job_with_brackets_in_its_text(world):
    world.job_end = ("rolled-back", "omacvm apply: rolled back [/] [bold]x[/bold")

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: a.c.jobs and not any(j.active for j in a.c.jobs.values()))
            await pilot.pause(0.5)
            assert list(a.c.jobs.values())[-1].state == "rolled-back"
    asyncio.run(go())


def test_dependency_asks_first(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("scroll-momentum"))
            await pilot.press("space")
            await pilot.pause(0.2)
            from omacvm_cc.tui import ConfirmScreen
            assert isinstance(a.screen, ConfirmScreen)
            await pilot.press("y")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            body = [b for _, p, b in world.requests if p == "/omacvm/jobs"][-1]
            assert body["action"] == "enable" and set(body["features"]) == {"scroll-momentum", "gestures"}
    asyncio.run(go())


def test_unavailable_does_not_ask_the_mac(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_status is not None)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("omanotch"))
            await pilot.press("space")
            await pilot.pause(0.3)
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
    asyncio.run(go())


def test_offline_banner_and_read_only(tmp_path, monkeypatch):
    checks = FakeChecks()
    for k, v in vm_env(str(tmp_path), 9, checks.path).items():   # nothing listens on port 9
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_error is not None)
            await pilot.pause(0.1)
            assert "does not answer" in a.banner()
            assert "Mac not reachable" in a.subtitle()
            await pilot.press("space")
            await pilot.pause(0.2)
            assert a.c.jobs == {}
    asyncio.run(go())
    checks.stop()


def test_older_mac_is_read_only(tmp_path, monkeypatch):
    mac, checks = FakeMac(old=True), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path).items():
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_error is not None)
            assert a.c.mac_error.kind == "old"
            assert "omacvm update on the Mac" in a.banner()
    asyncio.run(go())
    mac.stop()
    checks.stop()


def test_updates_screen_and_silence(world):
    world.manifest = {"version": "2.9.1", "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1",
                      "parts": {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.9.1", "note": "fewer missed swipes"},
                                "bridge": {"digest": "sha256:" + "b" * 64, "release": "2.7.0"}}}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.updates is not None and a.c.updates.get("manifest"))
            await pilot.pause(0.1)
            r = rows(a)
            assert r["gestures"].update and not r["bridge"].update
            await pilot.press("U")
            await pilot.pause(0.2)
            from omacvm_cc.tui import UpdatesScreen
            assert isinstance(a.screen, UpdatesScreen)
            await pilot.press("s")
            assert await settle(pilot, lambda: not world.checks_enabled)
            await pilot.press("i")
            await pilot.pause(0.2)
            await pilot.press("y")
            assert await settle(pilot, lambda: any(b == {"action": "update"} for _, p, b in world.requests if p == "/omacvm/jobs"))
    asyncio.run(go())


def test_report_has_no_personal_data(world, monkeypatch):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            await pilot.press("exclamation_mark")
            from omacvm_cc.tui import ReportScreen
            assert await settle(pilot, lambda: isinstance(a.screen, ReportScreen) and a.screen.rep is not None, 15)
            text = a.screen.rep.text
            for bad in ("ZorroNet", "a4:2b:b0", "Zorro's AirPods", "11:22:33:44:55:66", "Zorro Guest"):
                assert bad.lower() not in text.lower(), bad
            assert "### Versions" in text and "Apple M4 Max" in text
    asyncio.run(go())


def test_details_and_back(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.vm_checks is not None)
            await pilot.press("enter")
            await pilot.pause(0.2)
            from omacvm_cc.tui import DetailsScreen, FeaturesScreen
            assert isinstance(a.screen, DetailsScreen)
            await pilot.press("escape")
            await pilot.pause(0.1)
            assert isinstance(a.screen, FeaturesScreen)
            await pilot.press("q")
    asyncio.run(go())
