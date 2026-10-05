#!/usr/bin/env python3
"""Chromium's V4L2 decoder switch, AcceleratedVideoDecoder. Run AS THE USER
(install.sh does): chromium-flags.py on|off|check

Arch Linux ARM builds Chromium without VA-API; its V4L2 decoder is off unless
the feature is enabled. Chromium keeps only the LAST --enable-features of its
command line, and Arch's launcher reads /etc/chromium-flags.conf, then
~/.config/chromium-flags.conf (Omarchy's, which has one). So the feature goes
into the last --enable-features of the user's file (several flags may share a
line), or a new line with /etc's last list plus the feature when the user's
file has none. A marker in ~/.local/state/omacvm remembers what was added, so
"off" never removes what the user set. Written in place (a linked file stays
a link). check: exit 0 when Chromium would get the feature."""
import os, pwd, re, sys

FEATURE = "AcceleratedVideoDecoder"
SWITCH = "--enable-features="
ETC = "/etc/chromium-flags.conf"
HOME = pwd.getpwuid(os.getuid()).pw_dir   # not $HOME: runuser keeps root's
USER_FILE = f"{HOME}/.config/chromium-flags.conf"
MARK = f"{HOME}/.local/state/omacvm/chromium-v4l2-flags"
TOKEN = re.compile(r"(?<!\S)--enable-features=(\S*)")


def lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


def last_switch(ls):
    """(line index, match) of the last --enable-features, comments skipped."""
    found = None
    for i, l in enumerate(ls):
        if l.lstrip().startswith("#"):
            continue
        for m in TOKEN.finditer(l):
            found = (i, m)
    return found


def write(path, ls):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+") as f:   # in place: a link stays a link
        f.seek(0)
        f.truncate()
        f.write("".join(l + "\n" for l in ls))


def effective():
    for path in (USER_FILE, ETC):
        hit = last_switch(lines(path))
        if hit:
            return hit[1].group(1).split(",")
    return []


def on():
    if FEATURE in effective():
        return
    ls = lines(USER_FILE)
    hit = last_switch(ls)
    if hit:
        i, m = hit
        value = ",".join([x for x in m.group(1).split(",") if x] + [FEATURE])
        ls[i] = ls[i][:m.start()] + SWITCH + value + ls[i][m.end():]
        mark = "added"
    else:
        etc = last_switch(lines(ETC))
        base = [x for x in etc[1].group(1).split(",") if x] if etc else []
        ls.append(SWITCH + ",".join(base + [FEATURE]))
        mark = "line " + ls[-1]
    write(USER_FILE, ls)
    os.makedirs(os.path.dirname(MARK), exist_ok=True)
    with open(MARK, "w") as f:
        f.write(mark + "\n")


def off():
    try:
        with open(MARK) as f:
            mark = f.read().strip()
    except FileNotFoundError:
        return
    ls = lines(USER_FILE)
    if mark.startswith("line "):
        ls = [l for l in ls if l != mark[5:]]
    else:
        hit = last_switch(ls)
        if hit:
            i, m = hit
            rest = [x for x in m.group(1).split(",") if x and x != FEATURE]
            new = SWITCH + ",".join(rest) if rest else ""
            ls[i] = (ls[i][:m.start()] + new + ls[i][m.end():]).rstrip()
            if not ls[i].strip():
                del ls[i]
    write(USER_FILE, ls)
    os.remove(MARK)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "on":
        on()
    elif cmd == "off":
        off()
    elif cmd == "check":
        sys.exit(0 if FEATURE in effective() else 1)
    else:
        sys.exit("usage: chromium-flags.py on|off|check")
