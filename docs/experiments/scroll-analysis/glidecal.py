"""On-screen glide distance (video) per macOS momentum point (log), per glide
and side: 1.0 on macOS by definition; Omarchy should match."""
import numpy as np, sys
T0 = float(sys.argv[1]); VLAT = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
d = np.load("shifts2.npz"); vs = np.abs(d["shift"]); os_ = d["os"]; n = len(vs)
F = [l.split("\t") for l in open("input.tsv") if l.startswith("F")]
F = np.array([(float(p[1]), int(p[2]), int(p[5])) for p in F])
S = [l.split("\t") for l in open("input.tsv") if l.startswith("S")]
S = np.array([(float(p[1]), int(p[2]), int(p[3]), float(p[5])) for p in S])
# glides: macOS momentum sequences (phase 1 begin ... 3 end)
seqs, cur = [], None
for t, ph, mom, dy in S:
    if mom == 1: cur = [t, t, 0.0]; seqs.append(cur)
    if cur is not None and mom in (1, 2, 3): cur[1] = t; cur[2] += abs(dy)
    if mom == 3: cur = None
# offset: correlate macOS momentum per frame with video in macOS parts
def series(off):
    m = np.zeros(n); t = ((S[:, 0] - (T0 + off)) * 60)
    ok = (t >= 0) & (t < n); np.add.at(m, t[ok].astype(int), np.abs(S[ok, 3])); return m
mac = os_ == "mac"
off = max(np.arange(-2, 2.001, 1 / 120), key=lambda o: np.corrcoef(series(o)[mac], vs[mac])[0, 1])
res = {"mac": [], "oma": []}
for a, b, pts in seqs:
    if pts < 500: continue
    lat = VLAT if True else 0
    ia = int((a - T0 - off) * 60); ib = int((b - T0 - off) * 60) + 1
    side = os_[min(max(ia, 0), n - 1)]
    sh = int(round((VLAT if side == "oma" else 0) * 60))
    seg = vs[ia + sh:ib + sh + 6]
    px = seg[seg < 350].sum()
    res[side].append(px / pts)
for k in ("mac", "oma"):
    r = res[k]
    print(f"{k}: {len(r)} glides, on-screen px per momentum point: " + ", ".join(f"{x:.2f}" for x in r) +
          (f"  | median {np.median(r):.2f}" if r else ""))
