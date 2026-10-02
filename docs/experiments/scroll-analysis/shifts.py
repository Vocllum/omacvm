import numpy as np
W, H, B = 480, 850, 16
raw = np.memmap("wide.gray", dtype=np.uint8, mode="r")
n = raw.size // (W * H)
fr = raw[: n * W * H].reshape(n, H, W)
P = np.empty((n, H, B), np.float32)
for i in range(0, n, 200):
    P[i:i+200] = fr[i:i+200].reshape(-1, H, B, W // B).mean(axis=3)
P -= P.mean(axis=1, keepdims=True)
L = 2 * H
F = np.fft.rfft(P, n=L, axis=1)
lags = np.concatenate([np.arange(0, 420), np.arange(-420, 0)])
shift = np.zeros(n); qual = np.zeros(n); amb = np.zeros(n)
prev = 0.0
for t in range(1, n):
    c = np.fft.irfft((F[t] * np.conj(F[t - 1])).sum(axis=1), n=L)
    vals = np.concatenate([c[:420], c[-420:]]) / (H - np.abs(lags))
    norm = np.sqrt((P[t] ** 2).sum() * (P[t - 1] ** 2).sum()) / H + 1e-6
    vals = vals / norm
    gi = int(np.argmax(vals))
    # tracking: best peak within +-60 px of the previous shift, if nearly as good
    near = np.where(np.abs(lags - prev) <= 60)[0]
    ni = near[np.argmax(vals[near])]
    i = ni if vals[ni] >= 0.85 * vals[gi] else gi
    k = lags[i]
    if 0 < i < len(vals) - 1 and abs(lags[i+1]-lags[i]) == 1 and abs(lags[i]-lags[i-1]) == 1:
        a, b, d = vals[i-1], vals[i], vals[i+1]; den = a - 2*b + d
        off = 0.5 * (a - d) / den if den != 0 else 0.0
    else:
        off = 0.0
    shift[t] = k + off; qual[t] = vals[i]; amb[t] = 1 if i != gi else 0
    prev = shift[t] if qual[t] > 0.3 else 0.0
top = np.fromfile("top.rgb", dtype=np.uint8).reshape(-1, 3)[:n].astype(int)
os_tag = np.where(top[:, 2] > 80, "mac", "oma")
np.savez("shifts2.npz", shift=shift, qual=qual, os=os_tag, amb=amb)
for s in range(0, n, 60):
    seg = shift[s:s + 60]
    print(f"{s/60:5.1f}s {os_tag[s]} moved {np.abs(seg).sum():7.0f}px max {np.abs(seg).max():6.1f} lowqual {int((qual[s:s+60]<0.3).sum())} tracked {int(amb[s:s+60].sum())}")
