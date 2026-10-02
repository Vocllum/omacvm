"""Per gesture: where a two-finger swipe's movement goes (touch, steps arriving
after the lift, macOS's momentum; the guest's virtual movement in touch and
glide). Run in a folder with input.tsv and output.tsv."""
import numpy as np
VOFF = 0.035   # VM clock ahead of the Mac's (measure: date +%s.%N on both)
F = [l.split("\t") for l in open("input.tsv") if l.startswith("F")]
F = np.array([(float(p[1]), int(p[2]), float(p[4]) * 96, int(p[5])) for p in F])
S = [l.split("\t") for l in open("input.tsv") if l.startswith("S")]
S = np.array([(float(p[1]), int(p[2]), int(p[3]), float(p[5]), int(p[7])) for p in S])
V = [l.split("\t") for l in open("output.tsv") if l.startswith("V")]
V = np.array([(float(p[1]), int(p[2]), float(p[4])) for p in V])
runs, cur = [], None
for t, k, y, c in F:
    if k == 2:
        if cur and t - cur[1] < 0.05: cur[1] = t; cur[3] = y
        else: cur = [t, t, y, y, c]; runs.append(cur)
mv = lambda v: np.abs(np.diff(v[:, 2])[np.abs(np.diff(v[:, 2])) < 1500]).sum() if len(v) > 1 else 0
print(" side  dur  finger mm peak mm/s | macOS pt: touch  after-lift  momentum | virtual: touch  glide")
for a, b, y0, y1, c in runs:
    f = F[(F[:, 0] >= a) & (F[:, 0] <= b) & (F[:, 1] == 2)]
    if b - a < 0.03 or len(f) < 3: continue
    sp = np.abs(np.diff(f[:, 2])) / np.maximum(np.diff(f[:, 0]), 1e-3)
    if sp.max() < 100: continue
    st = S[(S[:, 0] >= a) & (S[:, 0] <= b) & (S[:, 2] == 0)]
    sa = S[(S[:, 0] > b) & (S[:, 0] < b + 0.15) & (S[:, 2] == 0) & (S[:, 1] != 0)]
    sm = S[(S[:, 0] > b) & (S[:, 0] < b + 2) & (S[:, 2] != 0)]
    vt = V[(V[:, 0] - VOFF >= a) & (V[:, 0] - VOFF <= b) & (V[:, 1] == 2)]
    vg = V[(V[:, 0] - VOFF > b) & (V[:, 0] - VOFF < b + 2) & (V[:, 1] == 2)]
    print(f" {'VM ' if c else 'mac'} {b-a:5.2f} {abs(y1-y0):8.1f} {sp.max():8.0f} | {abs(st[:,3]).sum():9.0f} {abs(sa[:,3]).sum():10.0f} {abs(sm[:,3]).sum():9.0f} | {mv(vt):13.0f} {mv(vg):6.0f}")
