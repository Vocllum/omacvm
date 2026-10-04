"""Status marks and words, shared by the TUI and the plain output. Nerd Font
glyphs (Omarchy ships JetBrainsMono Nerd Font), coloured from the terminal's
own palette; emoji are not used: their width differs between terminals and
breaks the columns. OMACVM_ASCII=1 (or a terminal without UTF-8): plain
letters."""
from __future__ import annotations

import locale
import os

from .state import Status

ASCII = os.environ.get("OMACVM_ASCII") == "1" or "utf" not in (locale.getpreferredencoding(False) or "").lower()

GLYPH = {
    Status.WORKS: ("", "ok"),         # nf-fa-check
    Status.NEEDS_PERSON: ("", "!"),   # nf-fa-warning
    Status.FAILING: ("", "x"),        # nf-fa-times
    Status.OFF: ("", "off"),          # nf-fa-circle_o
    Status.UNAVAILABLE: ("–", "-"),
    Status.UNKNOWN: ("?", "?"),
    Status.BUSY: ("⠋", "~"),
}
COLOR = {
    Status.WORKS: "green", Status.NEEDS_PERSON: "yellow", Status.FAILING: "red", Status.OFF: "bright_black",
    Status.UNAVAILABLE: "bright_black", Status.UNKNOWN: "bright_black", Status.BUSY: "cyan",
}
WORD = {
    Status.WORKS: "works", Status.NEEDS_PERSON: "needs you", Status.FAILING: "failing", Status.OFF: "off",
    Status.UNAVAILABLE: "not on this Mac", Status.UNKNOWN: "not checked", Status.BUSY: "working",
}
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
UPDATE = "^" if ASCII else ""     # nf-fa-arrow_up


def glyph(st: Status, tick: int = 0) -> str:
    if st is Status.BUSY and not ASCII:
        return SPINNER[tick % len(SPINNER)]
    return GLYPH[st][1 if ASCII else 0]


def ago(seconds: float) -> str:
    s = int(max(0, seconds))
    if s < 90:
        return "just now"
    if s < 5400:
        return f"{s // 60} min ago"
    if s < 172800:
        return f"{s // 3600} h ago"
    return f"{s // 86400} days ago"
