"""Scroll curve metrics from shifts2.npz: per gesture and OS."""
import numpy as np, sys
d = np.load(sys.argv[1] if len(sys.argv) > 1 else "shifts2.npz")
s, os_tag = np.abs(d["shift"]), d["os"]
n = len(s)
# gestures: runs of motion separated by >= 6 still frames, skipping app-switch frames (>350 px)
gest, cur, still = [], None, 0
for t in range(n):
    moving = s[t] >= 0.5 and s[t] < 350
    if moving:
        if cur is None: cur = [t, t]
        cur[1] = t; still = 0
    else:
        still += 1
        if cur and still >= 6:
            gest.append(tuple(cur)); cur = None
if cur: gest.append(tuple(cur))
rows = {"mac": [], "oma": []}
for a, b in gest:
    v = s[a:b + 1]
    if v.max() < 40 or b - a < 15: continue
    k = os_tag[a]
    pk = int(np.argmax(v)); vp = v[pk]
    r10 = next(i for i in range(len(v)) if v[i] >= 0.1 * vp)
    r90 = next(i for i in range(len(v)) if v[i] >= 0.9 * vp)
    # plateau: frames within 3 % of the peak
    plateau = int((np.abs(v - vp) <= 0.03 * vp).sum())
    # decay after the peak: fit log speed from 80 % down to 10 %
    tail = v[pk:]
    i80 = next((i for i in range(len(tail)) if tail[i] <= 0.8 * vp), None)
    i10 = next((i for i in range(len(tail)) if tail[i] <= 0.1 * vp), None)
    tau = rough = np.nan
    if i80 is not None and i10 is not None and i10 - i80 >= 4:
        seg = tail[i80:i10 + 1]
        x = np.arange(len(seg)); y = np.log(np.maximum(seg, 0.5))
        slope, icpt = np.polyfit(x, y, 1)
        tau = -1 / slope / 60 if slope < 0 else np.nan
        rough = float(np.std(y - (slope * x + icpt)))       # deviation from a clean exponential
    rows[k].append((a / 60, vp * 60, (r90 - r10) / 60, plateau, tau, rough, v.sum()))
for k, name in (("mac", "macOS"), ("oma", "Omarchy")):
    print(f"{name}: {len(rows[k])} gestures")
    print("   start  peak px/s  rise s  plateau fr  decay tau s  tail roughness  distance px")
    for r in rows[k]:
        print(f"  {r[0]:6.1f}  {r[1]:9.0f}  {r[2]:6.3f}  {r[3]:10d}  {r[4]:11.3f}  {r[5]:14.3f}  {r[6]:11.0f}")
    a = np.array(rows[k], float)
    if len(a):
        print(f"  median  {np.nanmedian(a[:,1]):9.0f}  {np.nanmedian(a[:,2]):6.3f}  {np.nanmedian(a[:,3]):10.0f}  {np.nanmedian(a[:,4]):11.3f}  {np.nanmedian(a[:,5]):14.3f}  {np.nanmedian(a[:,6]):11.0f}")
