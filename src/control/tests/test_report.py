"""Redaction: planted personal data must never survive into a report."""
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc import report as R  # noqa: E402

TOKEN = "9f2c4e1ab7d3c8e6f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b"
SSH_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq3Zorro0Testmann1Key2Fake3Data4Here5x zorro@zorro-mbp"


def known():
    k = R.Known()
    k.add("user", "zorro", "Zorro Testmann")
    k.add("host", "zorro-mbp", "Zorros-MacBook-Pro", "zorro-vm")
    k.add("vm", "Zorro's Omarchy")
    k.add("wifi", "ZorroNet 5G", "a4:2b:b0:11:22:33")
    k.add("bt", "Zorro's AirPods", "11:22:33:44:55:66")
    k.add("secret", TOKEN)
    k.add("home", "/home/zorro", "/Users/zorro")
    return k


FIXTURE = f"""
OK  Wi-Fi  ZorroNet 5G, -48 dBm (BSSID a4:2b:b0:11:22:33)
Oct 05 10:02:11 zorro-vm omacvm-gestures[812]: connect 10.211.55.2:47830 refused
Oct 05 10:02:12 zorro-vm omacvm-bridge-events[901]: Authorization: Bearer {TOKEN}
apply: VM 'Zorro's Omarchy' at 10.211.55.17, user zorro (Zorro Testmann)
Bluetooth: Zorro's AirPods (11:22:33:44:55:66) connected; also zorro’s airpods pro
path /home/zorro/.config/omacvm-bridge/token and /Users/zorro/Library/Logs/omacvm-bridge.log
key {SSH_KEY}
token={TOKEN[:40]} password: hunter2pass
mail zorro.testmann@example.com, ipv6 fe80::1c2b:3dff:fe4e:5f60 and 2a02:1210:abcd::42
uuid 5d3a2f53-e362-4d0f-9297-4e55da2fec76 serial "IOPlatformSerialNumber" = "C02ZK0ZZMD6R"
Zorros-MacBook-Pro.local said hi; ZORRO-MBP too; ｚｏｒｒｏ－ｍｂｐ in full width
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
-----END OPENSSH PRIVATE KEY-----
"""

PLANTED = ["zorro", "Testmann", "ZorroNet", "a4:2b:b0", "AirPods (11", "11:22:33:44:55:66", TOKEN[:16],
           "hunter2pass", "AAAAC3NzaC1lZDI1NTE5", "example.com", "10.211.55.17", "fe80::1c2b", "2a02:1210",
           "5d3a2f53", "C02ZK0ZZMD6R", "b3BlbnNzaC1rZXkt", "/home/", "/Users/"]


def test_nothing_planted_survives():
    text, counts = R.redact(FIXTURE, known())
    low = text.lower()
    for p in PLANTED:
        assert p.lower() not in low, (p, text)
    R.gate(text, known())   # must not raise
    assert counts["user"] >= 2 and counts["wifi"] >= 2 and counts["secret"] >= 2


def test_useful_parts_stay():
    text, _ = R.redact(FIXTURE, known())
    assert "<mac-parallels>:47830" in text
    assert "<ip-1>" in text
    assert "omacvm-gestures" in text
    assert "~/.config/omacvm-bridge/token" in text
    assert "10:02:11" in text   # times are not IPv6 addresses


def test_same_address_same_label():
    text, _ = R.redact("a 192.168.1.20 b 192.168.1.21 c 192.168.1.20", R.Known())
    assert text == "a <ip-1> b <ip-2> c <ip-1>"


def test_short_values_only_as_words():
    k = R.Known()
    k.add("user", "pi")
    text, _ = R.redact("pipewire runs for pi", k)
    assert text == "pipewire runs for <user>"


def test_long_paths_are_not_base64():
    p = "/usr/local/share/omacvm/bridge/guest/omacvmbridgeevents/extra/path"
    assert R.redact(p, R.Known())[0] == p


def test_gate_refuses_a_survivor():
    with pytest.raises(R.RedactionFailed):
        R.gate("hello ＺＯＲＲＯ－ＭＢＰ", known())


def test_counts_never_show_values():
    _, counts = R.redact(FIXTURE, known())
    line = R.taken_out(counts)
    assert "zorro" not in line.lower() and "user name" in line


def test_build_and_url():
    rep = R.build([("What happened", "zorro saw it"), ("Versions", "OmacVM 2.9.0"),
                   ("Logs (last 40 lines each)", "\n".join(f"line {i} at 10.211.55.{i % 200}" for i in range(400)))],
                  known(), "Gestures fail on zorro-mbp")
    assert rep.title == "Gestures fail on <host>"
    url, cut = R.issue_url(rep)
    assert cut and len(url) <= R.URL_MAX
    body = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["body"][0]
    assert "### Versions" in body and "OmacVM 2.9.0" in body and "zorro" not in body.lower()
    assert body.count("```") % 2 == 0 or "pasted below" in body


def test_short_report_is_not_cut():
    rep = R.build([("Versions", "OmacVM 2.9.0")], R.Known(), "t")
    url, cut = R.issue_url(rep)
    assert not cut and url.startswith(R.ISSUES)
