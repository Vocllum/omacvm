#!/usr/bin/env python3
"""docs/images/benchmarks.svg from report.py's JSON: each route as a share of the Mac.

  chart.py results.json docs/images/benchmarks.svg "MacBook Pro M4 Max · macOS 15.7 · 16 CPUs, 48 GB per VM"
"""
import json, sys
from xml.sax.saxutils import escape

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"
ROUTES = [  # report.py names (file names), label, colour
    ("mac", "macOS itself", "#e0def4"),
    ("parallels", "Parallels", "#9ccfd8"),
    ("utm", "UTM", "#c4a7e7"),
    ("fusion", "VMware Fusion", "#f6c177"),
    ("app", "OmacVM.app", "#ebbcba"),
]
TESTS = [
    ("geekbench-cpu-single", "CPU, one core", "Geekbench 7"),
    ("geekbench-cpu-multi", "CPU, all cores", "Geekbench 7"),
    ("speedometer", "Web apps", "Speedometer 3.1"),
    ("motionmark", "Graphics in the browser", "MotionMark 1.3.1"),
]


def main():
    data = json.load(open(sys.argv[1]))
    out, subtitle = sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
    med = data["medians"]
    tests = [t for t in TESTS if any(t[0] in med.get(r[0], {}) for r in ROUTES[1:])]
    routes = [r for r in ROUTES if r[0] in med]
    W, left, barw = 1000, 300, 600
    row, gap = 22, 26
    top = 120
    H = top + len(tests) * (len(routes) * row + gap) + 40
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">How fast Omarchy runs on each route, compared with macOS itself</title>']
    desc = []
    for key, label, bench in tests:
        base = med.get("mac", {}).get(key)
        parts = []
        for name, rl, _ in routes:
            v = med.get(name, {}).get(key)
            if v is None:
                parts.append(f"{rl}: " + data.get("missing", {}).get(name, {}).get(key, "not available"))
            elif base and name != "mac":
                parts.append(f"{rl}: {round(100 * v / base)} percent")
        desc.append(f"{label} ({bench}): " + ", ".join(parts))
    s.append(f'<desc id="d">{escape(". ".join(desc))}.</desc>')
    s.append('<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern></defs>')
    s.append(f'<rect width="{W}" height="{H}" fill="#191724"/><rect width="{W}" height="{H}" fill="url(#dots)"/>')
    s.append(f'<text x="{W/2}" y="40" text-anchor="middle" font-family="{FONT}" font-size="22" font-weight="600" fill="#e0def4">How fast is Omarchy in a VM?</text>')
    s.append(f'<text x="{W/2}" y="66" text-anchor="middle" font-family="{FONT}" font-size="14" fill="#908caa">{escape(subtitle)} · macOS itself = 100 %</text>')
    x = 330
    for name, rl, col in routes:
        s.append(f'<rect x="{x}" y="84" width="12" height="12" rx="3" fill="{col}"/>')
        s.append(f'<text x="{x + 18}" y="95" font-family="{FONT}" font-size="13" fill="#e0def4">{escape(rl)}</text>')
        x += 18 + len(rl) * 8 + 26
    y = top
    delay = 0.0
    for key, label, bench in tests:
        base = med.get("mac", {}).get(key)
        vals = [med.get(n, {}).get(key) for n, _, _ in routes]
        top_v = max([v for v in vals if v] + [base or 0]) or 1
        s.append(f'<text x="40" y="{y + 16}" font-family="{FONT}" font-size="15" font-weight="600" fill="#e0def4">{escape(label)}</text>')
        s.append(f'<text x="40" y="{y + 34}" font-family="{FONT}" font-size="12" fill="#6e6a86">{escape(bench)}</text>')
        for i, (name, rl, col) in enumerate(routes):
            v = med.get(name, {}).get(key)
            by = y + i * row
            if v is None:
                s.append(f'<text x="{left}" y="{by + 14}" font-family="{MONO}" font-size="12" fill="#6e6a86">{escape(data.get("missing", {}).get(name, {}).get(key, "not available"))}</text>')
                continue
            w = max(2, barw * v / top_v)
            s.append(f'<rect x="{left}" y="{by + 3}" width="{w:.1f}" height="14" rx="4" fill="{col}"/>')
            pct = "100 %" if name == "mac" else (f"{round(100 * v / base)} %" if base else f"{v:g}")
            s.append(f'<text x="{left + w + 8:.1f}" y="{by + 15}" font-family="{MONO}" font-size="12" fill="#e0def4">{pct}</text>')
            delay += 0.05
        y += len(routes) * row + gap
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


if __name__ == "__main__":
    main()
