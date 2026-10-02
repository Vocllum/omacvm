# Scroll curve analysis from a screen recording

Compares macOS's and Omarchy's scrolling in one screen recording (QuickTime,
60 fps, switching between macOS Chrome and the full-screen VM while doing the
same scrolls).

```bash
python3 -m venv venv && ./venv/bin/pip install numpy
F="Screen Recording.mov"
# a full-width strip of the page, 1 pixel = 1 CSS pixel at 2x, and the colour of
# the top bar (macOS Chrome purple vs Omarchy dark) to tell the systems apart
ffmpeg -i "$F" -vf "crop=2400:1700:560:420,scale=480:850,format=gray" -f rawvideo wide.gray
ffmpeg -i "$F" -vf "crop=200:24:300:46,scale=1:1,format=rgb24" -f rawvideo top.rgb
./venv/bin/python shifts.py      # per-frame page movement (FFT correlation of 16 bands, tracked)
./venv/bin/python metrics.py shifts2.npz
```

`metrics.py` prints per gesture: peak speed, rise time, frames at the peak
(a plateau means a cap), the exponential decay constant of the glide and its
roughness (deviation from a clean exponential), and the distance.
Crop coordinates fit a 3456 x 2234 recording of a full-screen browser; adjust
for others.
