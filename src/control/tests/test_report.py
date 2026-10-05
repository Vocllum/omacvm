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


def test_ipv4_at_the_end_of_a_sentence():
    text, _ = R.redact("connect to 192.168.1.20. then peer 10.211.55.32. done (at 10.0.0.7.)", R.Known())
    assert "192.168" not in text and "10.211" not in text and "10.0.0.7" not in text, text
    assert text == "connect to <ip-1>. then peer <ip-2>. done (at <ip-3>.)"


def test_dotted_versions_are_not_addresses():
    for v in ("1.2.3.4.5", "kernel 6.12.10.1.2"):
        assert R.redact(v, R.Known())[0] == v


def test_product_words_are_not_personal():
    k = R.Known()
    k.add("vm", "Omarchy", "Omarchy ARM", "Zorro's Omarchy")
    k.add("host", "omarchy", "alarm", "omarchy.local", "zorro-vm")
    k.add("user", "root")
    text, counts = R.redact("Omarchy 4.0.3 · /usr/share/omarchy/x · omarchy-menu · alarm clock · "
                            "VM Zorro's Omarchy on zorro-vm", k)
    assert text.startswith("Omarchy 4.0.3 · /usr/share/omarchy/x · omarchy-menu · alarm clock · "), text
    assert "Zorro" not in text and "zorro-vm" not in text
    assert counts.get("vm") == 1 and counts.get("host") == 1
    R.gate(text, k)


def test_mac_addresses_without_separators():
    text, _ = R.redact("net0 001C42EE41A6 up; macaddr=a4b2c3d4e5f6; MAC address: A4B2C3D4E5F7; "
                       "qemu 525400123456; cisco 001c.42ee.41a6", R.Known())
    for v in ("001C42EE41A6", "a4b2c3d4e5f6", "A4B2C3D4E5F7", "525400123456", "001c.42ee.41a6"):
        assert v.lower() not in text.lower(), (v, text)


def test_short_commit_hashes_stay():
    t = "OmacVM: the release (1b5c3f3a9e01) and 0123456789ab"
    assert R.redact(t, R.Known())[0] == t


def test_device_owner_names_in_every_spelling():
    # The VM's user is not the Mac owner: only the Bluetooth names know "Gilles".
    k = R.Known()
    k.add("user", "tester", "Test User")
    k.add("bt", "Gilles\u2019s AirPods Pro", "Gilles's Magic Keyboard", "Anna\u2018s iPhone", "Jo\u02bcs Mouse")
    text = ("connected: Gilles\u2019s AirPods Pro; also Gilles's AirPods Pro and Gilles's Magic Keyboard\n"
            'json "name": "Gilles\\u2019s AirPods Pro", "owner": "\\u0047illes"\n'
            "hello Gilles, Anna and Jo; GILLES\u2019S stuff\n")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    for name in ("Gilles", "gilles", "Anna", "Jo\u02bcs", "Jo's"):
        assert name not in out, (name, out)
    assert "<bt-device>" in out and "<user>" in out


def test_gate_sees_escapes_and_curly_apostrophes():
    k = R.Known()
    k.add("bt", "Gilles\u2019s AirPods")
    for leak in ("Gilles\\u2019s", "GILLES", "Gilles%27s", "Gill\\u0065s"):
        with pytest.raises(R.RedactionFailed):
            R.gate(leak, k)


@pytest.mark.parametrize("line,kept", [
    ("password: 'hunter2'", "password: '<secret>'"),
    ('password: "hunter 2 with spaces"', 'password: "<secret>"'),
    ("pass='x'", "pass='<secret>'"),
    ('"password": "hunter2"', '"password": "<secret>"'),
    ("{'api_key': 'abc123'}", "{'api_key': '<secret>'}"),
    ("[wifi]\npsk = 'Zorro PSK'", "[wifi]\npsk = '<secret>'"),
    ("db_password = s3cr3t", "db_password = <secret>"),
    ("auth-token: abc", "auth-token: <secret>"),
    ("credentials: 'x y'", "credentials: '<secret>'"),
    # A command line in the journal: quotes escaped once or more.
    ('bash -c "echo {\\"passphrase\\": \\"s3cr3t pass\\"}"', 'bash -c "echo {\\"passphrase\\": \\"<secret>\\"}"'),
    ('psk = \\\\\\"Zorro PSK\\\\\\"', 'psk = \\\\\\"<secret>\\\\\\"'),
])
def test_quoted_secrets(line, kept):
    out, counts = R.redact(line, R.Known())
    assert out == kept and counts.get("secret") == 1


def test_secret_words_inside_other_words_stay():
    for line in ("keyboard: us", "passes=3", "bypass: on", "monkey: 1"):
        assert R.redact(line, R.Known())[0] == line


def test_bluez_percent_encoded_and_zero_padded():
    k = R.Known()
    k.add("wifi", "Goetsch Home")
    out, _ = R.redact("dev_30_7A_D2_32_1E_AE paired; ssid Goetsch%20Home / Goetsch+Home / Goetsch_Home; "
                      "peer 010.211.055.032 and 192.168.001.010.", k)
    R.gate(out, k)
    assert "30_7A" not in out and "Goetsch" not in out and "055" not in out and "001.010" not in out
    assert "<hw-addr>" in out and out.count("<wifi>") == 3


def test_escapes_of_control_characters_stay_escaped():
    assert R.redact("ESC \\u001b[0m", R.Known())[0] == "ESC \\u001b[0m"


def test_mac_name_gives_its_owner():
    """ComputerName "Anna's MacBook Pro": Anna is a user name, also alone."""
    k = R.Known()
    k.add("user", "tester")
    k.add("host", "Anna’s MacBook Pro", "Annas-MacBook-Pro")
    out, _ = R.redact("Anna's iPhone paired; Anna said hi; host Annas-MacBook-Pro.local", k)
    R.gate(out, k)
    assert "Anna" not in out and "Annas" not in out
    assert "MacBook" not in R.redact("Mac: Anna's MacBook Pro", k)[0].replace("<host>", "")


def test_device_owner_without_known_values():
    """The Bridge is down (or a guest's own device): the owner's name before a
    device word goes by its form alone; product and plain words stay."""
    k = R.Known()
    for line, want in [
        ("/bluetooth/connect from 10.211.55.9: connected Anna’s AirPods", "connected <user>'s AirPods"),
        ("Anna's iPhone paired", "<user>'s iPhone paired"),
        ("James' Magic Keyboard", "<user>' Magic Keyboard"),
        ("host Annas-MacBook-Pro.local", "host <user>s-MacBook-Pro.local"),
    ]:
        out, counts = R.redact(line, k)
        assert want in out and counts.get("user") == 1, out
    for line in ("Magic Keyboard connected", "Apple's Magic Mouse", "My iPhone", "Parallels-Mac", "omarchy-MacBook"):
        assert R.redact(line, k)[0] == line


@pytest.mark.parametrize("line,gone", [
    ("unit omacvm-wifi@ZorroNet\\x205G.service started", "ZorroNet"),
    ("user J\\xc3\\xbcrgen logged in", "rgen"),
    ("user J\\xfcrgen (latin-1)", "rgen"),
    ('json "ZorroNet\\\\x205G"', "ZorroNet"),
])
def test_hex_escapes_decoded(line, gone):
    k = R.Known()
    k.add("wifi", "ZorroNet 5G")
    k.add("user", "Jürgen")
    out, _ = R.redact(line, k)
    R.gate(out, k)
    assert gone not in out, out


def test_hex_escapes_gate():
    k = R.Known()
    k.add("user", "Jürgen")
    with pytest.raises(R.RedactionFailed):
        R.gate("J\\xc3\\xbcrgen", k)
    assert R.redact("ESC \\x1b[0m", R.Known())[0] == "ESC \\x1b[0m"


@pytest.mark.parametrize("line,kept", [
    ("iwctl --passphrase hunter2 station wlan0 connect X", "iwctl --passphrase <secret> station wlan0 connect X"),
    ("nmcli dev wifi connect X password hunter2", "nmcli dev wifi connect X password <secret>"),
    ("nmcli con modify x wifi-sec.psk hunter2", "nmcli con modify x wifi-sec.psk <secret>"),
    ("nmcli con modify x 802-11-wireless-security.psk 'two words'", "nmcli con modify x 802-11-wireless-security.psk <secret>"),
    ("tool -password Hunter --x", "tool -password <secret> --x"),
    ("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic <secret>"),
    ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 used", "token <secret> used"),
    ("github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv", "<secret>"),
    ("gho_ABCDEFGHIJKLMNOPQRSTUVWX12", "<secret>"),
])
def test_secret_as_next_argument_and_tokens(line, kept):
    out, counts = R.redact(line, R.Known())
    assert out == kept and counts.get("secret") == 1, out


def test_secret_words_in_plain_text_stay():
    for line in ("the password was wrong", "password incorrect", "Basic setup done", "Basic Configuration",
                 "--password-file /etc/x", "psk mismatch"):
        assert R.redact(line, R.Known())[0] == line


def test_mac_known_without_bridge(monkeypatch):
    """omacvm report on the Mac with the Bridge down: names from the Mac itself
    (full and first name, the Mac's name's owner, Bluetooth via system_profiler)."""
    import json
    from omacvm_cc import collect, bridge
    sp = json.dumps({"SPBluetoothDataType": [{"controller_properties": {"controller_address": "AA:BB:CC:DD:EE:FF"},
                                               "device_connected": [{"Bea’s AirPods Pro": {"device_address": "11:22:33:44:55:66"}}],
                                               "device_not_connected": [{"Living Room Speaker": {}}]}]})
    outs = {"id": "Al Testmann", "dscl": "FirstName: Al\nNo such key: LastName", "scutil": "Cleo’s MacBook Pro",
            "system_profiler": sp}

    def fake_run(cmd, timeout=10.0):
        return outs.get(cmd[0], "")
    monkeypatch.setattr(collect, "run", fake_run)

    def down(self, *a, **kw):
        raise OSError("connection refused")
    monkeypatch.setattr(bridge.Bridge, "call", down)
    k = collect.mac_known("/nonexistent/omacvm")
    text = ("Al opened it; Al Testmann; Cleo's iPad; Cleo alone; Bea alone; Bea's AirPods Pro (11:22:33:44:55:66); "
            "Living Room Speaker on; Dana's AirPods")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    for name in ("Al ", "Testmann", "Cleo", "Bea", "Living Room", "11:22:33", "Dana"):
        assert name not in out, (name, out)
    assert "No such key" not in " ".join(v for _, v in k.items())
