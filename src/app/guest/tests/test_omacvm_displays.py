#!/usr/bin/env python3
"""Tests for omacvm-displays' wallpaper check (no VM needed).

    python3 src/app/guest/tests/test_omacvm_displays.py
"""
import importlib.machinery
import importlib.util
import pathlib
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("omacvm_displays", str(HERE.parent / "omacvm-displays"))
spec = importlib.util.spec_from_loader("omacvm_displays", loader)
od = importlib.util.module_from_spec(spec)
loader.exec_module(od)


def mon(name, x, y, w, h, scale=2.0, **extra):
    m = {"name": name, "x": x, "y": y, "width": w, "height": h, "scale": scale, "transform": 0}
    m.update(extra)
    return m


def layers(**per_output):
    """layers(Virtual_1=[(ns, x, y, w, h), ...]) -> j/layers shape."""
    out = {}
    for key, items in per_output.items():
        name = key.replace("_", "-")
        out[name] = {"levels": {"0": [{"address": "0x1", "x": x, "y": y, "w": w, "h": h,
                                       "namespace": ns, "pid": 1} for ns, x, y, w, h in items],
                                "1": [], "2": [], "3": []}}
    return out


# The user's 2.8.0 test: external 3840x2400 @2 (Virtual-1), MacBook 3456x2160 @2 left of it.
MONS = [mon("Virtual-1", 1728, 0, 3840, 2400), mon("Virtual-2", 0, 0, 3456, 2160),
        mon("NOTCH", 0, 0, 3456, 74)]


class MisplacedWallpapers(unittest.TestCase):
    def test_all_in_place(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1728, 1080)],
                   NOTCH=[("omarchy-background", 0, 0, 1728, 37)])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_left_behind_after_a_move(self):
        # Virtual-2 came up to the right of Virtual-1, then moved to the left.
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 3648, 0, 1728, 1080)])
        self.assertEqual(od.misplaced_wallpapers(MONS, l),
                         ["Virtual-2: wallpaper at 3648,0 1728x1080, display at 0,0 1728x1080"])

    def test_wrong_size(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1024, 768)])
        self.assertEqual(len(od.misplaced_wallpapers(MONS, l)), 1)

    def test_fractional_rounding_is_fine(self):
        mons = [mon("Virtual-1", 0, 0, 3024, 1964, scale=1.6)]  # 1890 x 1227.5
        l = layers(Virtual_1=[("omarchy-background", 0, 0, 1890, 1228)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_no_shell_no_report(self):
        l = layers(Virtual_1=[("omarchy-bar", 1728, 0, 1920, 26)], Virtual_2=[])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_missing_layer_is_left_alone(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)], Virtual_2=[])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_notch_and_mirrors_ignored(self):
        mons = MONS[:2] + [mon("NOTCH", 0, 0, 3456, 74), mon("Virtual-3", 0, 0, 3456, 2160, mirrorOf="Virtual-2")]
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1728, 1080)],
                   Virtual_3=[("omarchy-background", 99, 99, 10, 10)],
                   NOTCH=[("omarchy-background", 500, 500, 1, 1)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_disabled_and_rotated(self):
        mons = [mon("Virtual-1", 0, 0, 2400, 3840, transform=1), mon("Virtual-2", 0, 0, 100, 100, disabled=True)]
        l = layers(Virtual_1=[("omarchy-background", 0, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 9, 9, 9, 9)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_garbage_input(self):
        for m, l in [(None, None), ([], {}), ("x", "y"), ([1, None], {"a": 1}),
                     (MONS, {"Virtual-2": {"levels": {"0": [None, 3]}}})]:
            self.assertEqual(od.misplaced_wallpapers(m, l), [])


class Agent(unittest.TestCase):
    """check_wallpapers: settle, confirm, then repair once, rate-limited."""

    def make(self, problems):
        self.problems = problems
        a = od.Agent.__new__(od.Agent)
        a.layout_at = -100.0
        a.suspect = None
        a.repairs = 0
        a.repaired_at = -od.REPAIR_EVERY
        a.repair = None
        a.repaired_for = []
        a.said = []
        self.started = []
        self.clock = [1000.0]
        test = self

        class P:
            def __init__(self, argv, **kw):
                test.started.append(argv)

            def poll(self):
                return 0
        for target, value in [("misplaced_wallpapers", lambda m, l: list(self.problems)),
                              ("hypr_json", lambda c: None),
                              ("config_flag", lambda n: True),
                              ("REPAIRS", pathlib.Path("/nonexistent/omacvm-test/shell-repairs"))]:
            patcher = mock.patch.object(od, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for patcher in (mock.patch.object(od.time, "monotonic", lambda: self.clock[0]),
                        mock.patch.object(od.subprocess, "Popen", P)):
            patcher.start()
            self.addCleanup(patcher.stop)
        return a

    def test_confirm_then_repair_then_rate_limit(self):
        a = self.make(["Virtual-2: x"])
        a.check_wallpapers()                      # first sight
        self.assertEqual(self.started, [])
        self.clock[0] += 2
        a.check_wallpapers()                      # too soon to confirm
        self.assertEqual(self.started, [])
        self.clock[0] += 5
        a.check_wallpapers()                      # confirmed: restart
        self.assertEqual(self.started, [["omarchy-restart-shell"]])
        for _ in range(4):                        # within REPAIR_EVERY: no more
            self.clock[0] += 10
            a.check_wallpapers()
        self.assertEqual(len(self.started), 1)

    def test_layout_change_resets(self):
        a = self.make(["Virtual-2: x"])
        a.check_wallpapers()
        self.clock[0] += 5
        a.layout_changed()
        self.clock[0] += 1
        a.check_wallpapers()                      # still settling
        self.clock[0] += 5
        a.check_wallpapers()                      # first sight again
        self.assertEqual(self.started, [])

    def test_at_most_three(self):
        a = self.make(["Virtual-2: x"])
        for i in range(40):
            self.problems = [f"Virtual-2: at {i // 2}"]  # a new place each time
            self.clock[0] += od.REPAIR_EVERY / 2
            a.check_wallpapers()
        self.assertEqual(len(self.started), od.REPAIR_MAX)

    def test_same_after_restart_stops(self):
        # A fresh shell with exactly the same report: not a surface left
        # behind; one restart only.
        a = self.make(["Virtual-2: x"])
        for _ in range(40):
            self.clock[0] += od.REPAIR_EVERY / 2
            a.check_wallpapers()
        self.assertEqual(len(self.started), 1)

    def test_switched_off(self):
        a = self.make(["Virtual-2: x"])
        with mock.patch.object(od, "config_flag", lambda n: n != "repair-shell"):
            for _ in range(10):
                self.clock[0] += od.REPAIR_EVERY
                a.check_wallpapers()
        self.assertEqual(self.started, [])


if __name__ == "__main__":
    unittest.main()
