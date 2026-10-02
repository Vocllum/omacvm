"""Line up a screen recording with omacvm-input.tsv (Mac) and omacvm-output.tsv (VM)
and compare macOS's and Omarchy's scrolling against the same finger input."""
import numpy as np, sys, calendar, time
T0 = float(sys.argv[1])                     # recording start (unix, from the file's metadata)
TPW, TPH = 156.0, 96.0                      # trackpad size, mm (MacBook Pro 16")
d = np.load("shifts2.npz"); vs = np.abs(d["shift"]) * 60; os_ = d["os"]; n = len(vs)
F, S = [], []
for l in open("input.tsv"):
    p = l.rstrip("\n").split("\t")
    if p[0] == "F": F.append((float(p[1]), int(p[2]), float(p[3]), float(p[4])))
    elif p[0] == "S": S.append((float(p[1]), int(p[2]), int(p[3]), float(p[4]), float(p[5])))
F, S = np.array(F), np.array(S)
# macOS's scroll magnitude per video frame for a given offset; correlate with the video in macOS parts
def series(off):
    t = (S[:, 0] - (T0 + off)) * 60
    m = np.zeros(n)
    ok = (t >= 0) & (t < n)
    np.add.at(m, t[ok].astype(int), np.abs(S[ok, 4]) * 60)
    return m
mac = os_ == "mac"
best = max(np.arange(-2, 2.001, 1 / 120), key=lambda o: np.corrcoef(series(o)[mac], vs[mac])[0, 1])
print(f"offset {best:+.3f} s (video starts at {time.strftime('%H:%M:%S', time.localtime(T0 + best))})")
T = T0 + best
# finger speed per video frame (two fingers down), mm/s along y
ft = (F[:, 0] - T) * 60
fspeed = np.full(n, np.nan); down = np.zeros(n, bool)
two = F[F[:, 1] == 2]
for i in range(1, len(two)):
    dt = two[i, 0] - two[i - 1, 0]
    if 0 < dt < 0.05:
        k = int((two[i, 0] - T) * 60)
        if 0 <= k < n:
            v = abs(two[i, 3] - two[i - 1, 3]) * TPH / dt
            fspeed[k] = v if np.isnan(fspeed[k]) else max(fspeed[k], v)
            down[k] = True
# transfer: output px/s vs finger mm/s while touching, by speed band
bands = [(0, 10), (10, 30), (30, 60), (60, 100), (100, 160), (160, 250), (250, 400), (400, 2000)]
print("\nWhile touching: output px/s per finger mm/s (median gain), by finger speed")
print("  finger mm/s     macOS gain  (n)    Omarchy gain  (n)   Omarchy/macOS")
for a, b in bands:
    g = {}
    for k in ("mac", "oma"):
        sel = down & (os_ == k) & (fspeed >= a) & (fspeed < b) & (vs > 0)
        sel &= ~np.isnan(fspeed)
        g[k] = (np.median(vs[sel] / np.maximum(fspeed[sel], 1e-3)), int(sel.sum())) if sel.sum() >= 3 else (np.nan, int(sel.sum()))
    ratio = g["oma"][0] / g["mac"][0] if g["mac"][0] and not np.isnan(g["mac"][0]) else np.nan
    print(f"  {a:4d}-{b:<5d}      {g['mac'][0]:7.1f}  ({g['mac'][1]:3d})     {g['oma'][0]:7.1f}  ({g['oma'][1]:3d})     {ratio:6.2f}")
# glides: lift = end of a run of two-finger frames; take the video speed at the lift and after
print("\nAfter lifting: speed at the lift, distance and decay of the glide")
lifts = [i for i in range(1, len(F)) if F[i - 1, 1] == 2 and (F[i, 1] != 2 or F[i, 0] - F[i - 1, 0] > 0.05)]
for k in ("mac", "oma"):
    rows = []
    for i in lifts:
        f = int((F[i - 1, 0] - T) * 60)
        if not (0 <= f < n - 90) or os_[f] != k: continue
        v0 = np.median(vs[max(f - 2, 0):f + 1])
        if v0 < 1500: continue
        tail = vs[f:f + 120]
        stop = next((j for j in range(len(tail)) if tail[j] < 60), len(tail))
        dist = tail[:stop].sum() / 60
        seg = tail[:stop]; x = np.arange(len(seg))
        tau = np.nan
        if len(seg) > 6:
            sl = np.polyfit(x, np.log(np.maximum(seg, 1)), 1)[0]
            tau = -1 / sl / 60 if sl < 0 else np.nan
        rows.append((v0, dist, stop / 60, tau, dist / v0))
    print(f"  {k}: {len(rows)} glides")
    for r in rows: print(f"    lift speed {r[0]:6.0f} px/s  glide {r[1]:6.0f} px over {r[2]:.2f} s  tau {r[3]:.3f} s  distance/speed {r[4]:.3f} s")
    if rows:
        a = np.array(rows); print(f"    median distance/speed {np.median(a[:,4]):.3f} s, tau {np.nanmedian(a[:,3]):.3f} s")
