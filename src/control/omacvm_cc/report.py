"""Report a problem: collect what helps (checks, versions, recent logs),
take out what is personal, show it, then open a pre-filled GitHub issue.
Nothing is uploaded by OmacVM: the browser opens a form the person submits.

Redaction, in this order:
 1. Known values (exact, case-insensitive, longest first): user and full
    names, host names, VM names, Wi-Fi names and BSSIDs, Bluetooth names and
    addresses, the Bridge token, home folders.
 2. Patterns: PEM blocks, SSH keys, bearer tokens, key=value secrets, e-mail
    addresses, hardware addresses, UUIDs, serial numbers, IPv4/IPv6
    addresses (the Mac's VM-network addresses get a label), long hex and
    base64 runs.
 3. Gate: if any known value is still in the text after Unicode
    normalisation, the report is refused (RedactionFailed), never shown or sent.

Also runs on the Mac (`omacvm report`) with macOS's /usr/bin/python3 3.9:
stdlib only, no newer syntax outside annotations.
"""
from __future__ import annotations

import re
import unicodedata
import urllib.parse
from dataclasses import dataclass, field

ISSUES = "https://github.com/gillesgoetsch/omacvm/issues/new"
URL_MAX = 7000   # browsers and GitHub cut longer URLs

# The Mac's address on each VM network: kept apart, but not personal.
MAC_ADDRS = {"10.211.55.2": "<mac-parallels>", "192.168.64.1": "<mac-utm>", "10.0.2.2": "<mac-app>"}
KEEP_ADDRS = {"127.0.0.1", "0.0.0.0", "255.255.255.255"}

LABELS = {"user": "<user>", "host": "<host>", "vm": "<vm>", "wifi": "<wifi>",
          "bt": "<bt-device>", "secret": "<secret>"}
NOUNS = {"user": "user name", "host": "host name", "vm": "VM name", "wifi": "Wi-Fi name",
         "bt": "Bluetooth device", "secret": "secret", "home": "home folder", "ip": "address",
         "hw": "hardware address", "email": "e-mail address", "key": "key", "uuid": "ID",
         "serial": "serial number"}


class RedactionFailed(Exception):
    pass


@dataclass
class Known:
    """Values that must never leave the machine, by kind."""
    user: list = field(default_factory=list)
    host: list = field(default_factory=list)
    vm: list = field(default_factory=list)
    wifi: list = field(default_factory=list)
    bt: list = field(default_factory=list)
    secret: list = field(default_factory=list)
    home: list = field(default_factory=list)

    def add(self, kind: str, *values) -> None:
        lst = getattr(self, kind)
        for v in values:
            v = norm(str(v or "")).strip()
            if len(v) >= 2 and not self.has(v):
                lst.append(v)
            # A full name's parts too ("Zorro Testmann": "Zorro", "Testmann").
            if kind in ("user", "bt") and " " in v:
                for part in v.replace("'s", " ").split():
                    if len(part) >= 3 and part.lower() not in COMMON and not self.has(part):
                        lst.append(part)

    def has(self, v: str) -> bool:
        return any(v.casefold() == w.casefold() for _, w in self.items())

    def items(self):
        for kind in ("secret", "wifi", "vm", "host", "user", "bt"):
            for v in getattr(self, kind):
                yield kind, v


# Words in device and person names that are not personal on their own.
COMMON = {"airpods", "pro", "max", "macbook", "magic", "keyboard", "mouse", "trackpad", "iphone", "ipad",
          "the", "and", "von", "van", "der", "mini", "air", "studio", "imac", "headphones", "speaker"}


def norm(s: str) -> str:
    """NFKC: full-width and other look-alike forms become plain letters."""
    return unicodedata.normalize("NFKC", s)


def _value_re(v: str) -> re.Pattern:
    """Short values (< 4) only as whole words: "pi" must not eat "pipewire"."""
    e = re.escape(v)
    if len(v) < 4:
        e = r"(?<![A-Za-z0-9])" + e + r"(?![A-Za-z0-9])"
    return re.compile(e, re.IGNORECASE)


PATTERNS = [
    ("key", re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S), "<key>"),
    ("key", re.compile(r"\b(?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\s+[A-Za-z0-9+/=]{16,}(?:\s+\S+)?"), "<ssh-key>"),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<email>"),
    ("secret", re.compile(r"(?i)\b(Bearer)\s+[^\s\"']+"), r"\1 <secret>"),
    ("secret", re.compile(r"(?i)\b((?:[a-z_]*_)?(?:token|password|passwd|secret|psk|api_?key|key))(\"?\s*[=:]\s*\"?)(?!<)([^\s\"',;}]+)"),
     r"\1\2<secret>"),
    ("serial", re.compile(r"(?i)(IOPlatformSerialNumber\"?\s*=?\s*\"?|Serial Number(?: \(system\))?:\s*)([A-Z0-9]{6,})"), r"\1<serial>"),
    ("uuid", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    ("hw", re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"), "<hw-addr>"),
    ("secret", re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<secret>"),
]
# Base64 runs of 40 or more: only with digits and both cases, so a long path
# (letters and slashes) stays.
B64 = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}")
IPV4 = re.compile(r"(?<![\d.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\d.])")
IPV6 = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,6}(?::[0-9A-Fa-f]{1,4}){1,6})(?![0-9A-Fa-f:])")
HOMES = re.compile(r"(/Users|/home)/(?!<)[^/\s:'\"]+")
TIME_LIKE = re.compile(r"^\d{1,2}(?::\d{2}){1,2}$")


def redact(text: str, known: Known, mac_addrs: dict | None = None) -> tuple[str, dict]:
    """Returns the text without personal data, and how many of each kind went."""
    counts: dict = {}

    def bump(kind: str, n: int = 1) -> None:
        if n:
            counts[kind] = counts.get(kind, 0) + n

    text = norm(text)
    # Home folders first, so "/home/zorro/x" becomes "~/x", not "/home/<user>/x".
    for h in sorted(known.home, key=len, reverse=True):
        text, n = re.subn(re.escape(h.rstrip("/")) + r"(?=/|\b|$)", "~", text)
        bump("home", n)
    text, n = HOMES.subn("~", text)
    bump("home", n)
    # Keys and e-mail addresses whole, before their parts match a name.
    for kind, rx, repl in PATTERNS[:3]:
        text, n = rx.subn(repl, text)
        bump(kind, n)
    # 1. Known values, longest first over all kinds (a VM named after its user).
    for kind, v in sorted(known.items(), key=lambda kv: len(kv[1]), reverse=True):
        text, n = _value_re(v).subn(LABELS[kind], text)
        bump(kind, n)
    # 2. Patterns.
    for kind, rx, repl in PATTERNS[3:]:
        text, n = rx.subn(repl, text)
        bump(kind, n)

    def b64(m: re.Match) -> str:
        v = m.group(0)
        if re.search(r"\d", v) and re.search(r"[a-z]", v) and re.search(r"[A-Z]", v):
            bump("secret")
            return "<secret>"
        return v
    text = B64.sub(b64, text)
    labels = dict(MAC_ADDRS, **(mac_addrs or {}))
    seen: dict = {}

    def ip(m: re.Match) -> str:
        a = m.group(1)
        if a in KEEP_ADDRS:
            return a
        if a in labels:
            return labels[a]
        if a not in seen:
            seen[a] = f"<ip-{len(seen) + 1}>"
        bump("ip")
        return seen[a]
    text = IPV4.sub(ip, text)

    def ip6(m: re.Match) -> str:
        a = m.group(1)
        if a in ("::1", "::") or TIME_LIKE.match(a) or a.count(":") < 2:
            return a
        if a not in seen:
            seen[a] = f"<ip6-{sum(1 for k in seen if ':' in k) + 1}>"
        bump("ip")
        return seen[a]
    text = IPV6.sub(ip6, text)
    return text, counts


def gate(text: str, known: Known) -> None:
    """Refuse when any known value survived (NFKC and case folded)."""
    t = unicodedata.normalize("NFKC", text).casefold()
    for kind, v in known.items():
        w = unicodedata.normalize("NFKC", v).casefold()
        if len(w) < 4:
            if re.search(r"(?<![a-z0-9])" + re.escape(w) + r"(?![a-z0-9])", t):
                raise RedactionFailed(kind)
        elif w in t:
            raise RedactionFailed(kind)


def taken_out(counts: dict) -> str:
    """'3 user names, 1 address': never the values."""
    parts = []
    for kind, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        noun = NOUNS.get(kind, kind)
        if n != 1:
            noun = "addresses" if noun == "address" else ("Wi-Fi names" if noun == "Wi-Fi name" else noun + "s")
        parts.append(f"{n} {noun}")
    return ", ".join(parts) if parts else "nothing personal found"


@dataclass
class Report:
    text: str
    counts: dict
    title: str


def build(sections: list, known: Known, title: str, mac_addrs: dict | None = None) -> Report:
    """sections: (heading, body) pairs. Redacts, gates, returns the report."""
    md = []
    for heading, body in sections:
        body = body.rstrip()
        if body:
            md.append(f"### {heading}\n{body}" if heading == "What happened" else f"### {heading}\n```\n{body}\n```")
    text, counts = redact("\n\n".join(md) + "\n", known, mac_addrs)
    t, c2 = redact(title, known, mac_addrs)
    gate(text + t, known)
    for k, v in c2.items():
        counts[k] = counts.get(k, 0) + v
    return Report(text=text, counts=counts, title=t)


def issue_url(report: Report) -> tuple[str, bool]:
    """The pre-filled issue URL; True when the text had to be cut (the rest
    goes to the clipboard and the issue says so)."""
    def url(body: str) -> str:
        return ISSUES + "?" + urllib.parse.urlencode({"title": report.title, "body": body, "labels": "bug"})
    full = url(report.text)
    if len(full) <= URL_MAX:
        return full, False
    note = "\n\n_The full report did not fit in the link: it is on the clipboard, pasted below._\n"
    lines = report.text.splitlines()
    logs = next((i for i, l in enumerate(lines) if l.startswith("### Logs")), None)
    # The logs' oldest lines go first; checks and versions stay.
    while lines and len(url("\n".join(lines) + note)) > URL_MAX:
        if logs is not None and logs + 2 < len(lines) and lines[logs + 2] != "```":
            del lines[logs + 2]
        else:
            lines.pop()
    return url("\n".join(lines) + note), True
