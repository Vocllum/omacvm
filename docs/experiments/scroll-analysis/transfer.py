"""Transfer curves from the logs: macOS points per finger mm (macOS parts) and
Omarchy's virtual units per finger mm (VM parts), converted to on-screen px
with a factor fitted against the video."""
import numpy as np, sys
T0 = float(sys.argv[1]); TPH = 96.0; WIN = 0.05
d = np.load("shifts2.npz"); vs = np.abs(d["shift"]) * 60; os_ = d["os"]; n = len(vs)
F, S, V = [], [], []
for l in open("input.tsv"):
    p = l.rstrip("\n").split("\t")
    if p[0] == "F": F.append((float(p[1]), int(p[2]), float(p[4]), int(p[5])))
    elif p[0] == "S": S.append((float(p[1]), int(p[2]), int(p[3]), float(p[5]), int(p[7])))
for l in open("output.tsv"):
    p = l.rstrip("\n").split("\t")
    if p[0] == "V": V.append((float(p[1]), int(p[2]), float(p[4])))
F, S, V = np.array(F), np.array(S), np.array(V)
# windows of WIN seconds with two fingers down the whole time
two = F[F[:, 1] == 2]
t_start, t_end = two[0, 0], two[-1, 0]
rows = []
for a in np.arange(t_start, t_end, WIN):
    b = a + WIN
    f = two[(two[:, 0] >= a) & (two[:, 0] < b)]
    if len(f) < 4 or np.any(np.diff(f[:, 0]) > 0.03): continue
    mm = abs(f[-1, 2] - f[0, 2]) * TPH
    dtt = f[-1, 0] - f[0, 0]
    if dtt <= 0 or mm < 0.2: continue
    speed = mm / dtt
    cap = int(np.median(f[:, 3]))
    if cap == 0:   # macOS part: macOS's own scroll (finger phase, no momentum)
        sw = S[(S[:, 0] >= a) & (S[:, 0] < b) & (S[:, 2] == 0)]
        if len(sw) == 0: continue
        rows.append(("mac", speed, abs(sw[:, 3]).sum() / mm))
    else:          # VM part: the virtual centre's movement
        vw = V[(V[:, 0] >= a) & (V[:, 0] < b) & (V[:, 1] == 2)]
        if len(vw) < 3: continue
        dv = np.diff(vw[:, 2]); dtv = np.diff(vw[:, 0])
        # only steps within one touch: no restarts (jumps) and no gaps
        okv = (dtv > 0) & (dtv < 0.02) & (np.abs(dv) < 1500)
        if okv.sum() < 2 or okv.mean() < 0.8: continue
        rows.append(("oma", speed, abs(dv[okv].sum()) / mm))
# units -> on-screen px: in VM parts, video speed / virtual speed during glides and touches
vt = (V[:, 0] - T0) * 60
units_per_s = np.full(n, np.nan)
for k in range(1, len(V)):
    if V[k, 1] == 2 and V[k - 1, 1] == 2 and 0 < V[k, 0] - V[k - 1, 0] < 0.02 and abs(V[k, 2] - V[k - 1, 2]) < 1500:
        i = int(vt[k])
        if 0 <= i < n and os_[i] == "oma":
            units_per_s[i] = abs(V[k, 2] - V[k - 1, 2]) / (V[k, 0] - V[k - 1, 0])
# Total distance over the VM part (robust to the VM's display delay): all
# on-screen movement against all virtual movement within touches.
oma = os_ == "oma"
ia, ib = np.where(oma)[0][[0, -1]]
ta, tb = T0 + ia / 60, T0 + ib / 60
Vs = V[(V[:, 0] >= ta) & (V[:, 0] <= tb)]
dv = np.diff(Vs[:, 2]); dtv = np.diff(Vs[:, 0])
same = (Vs[1:, 1] == 2) & (Vs[:-1, 1] == 2) & (dtv < 0.05) & (np.abs(dv) < 1500)
units_total = np.abs(dv[same]).sum()
px_total = vs[ia:ib + 1][vs[ia:ib + 1] < 350 * 60].sum() / 60
k_px = px_total / units_total if units_total else np.nan
print(f"on-screen px per virtual unit: {k_px:.3f} ({px_total:.0f} px / {units_total:.0f} units)")
bands = [(0, 10), (10, 20), (20, 40), (40, 70), (70, 110), (110, 170), (170, 260), (260, 400), (400, 3000)]
print("finger mm/s   macOS px/mm (n)   Omarchy px/mm (n)   Omarchy/macOS")
for a, b in bands:
    m = [r[2] for r in rows if r[0] == "mac" and a <= r[1] < b]
    o = [r[2] * k_px for r in rows if r[0] == "oma" and a <= r[1] < b]
    mm_ = np.median(m) if len(m) >= 2 else np.nan
    om_ = np.median(o) if len(o) >= 2 else np.nan
    print(f"  {a:4d}-{b:<5d}   {mm_:7.2f} ({len(m):3d})   {om_:7.2f} ({len(o):3d})      {om_/mm_ if mm_ else np.nan:5.2f}")
