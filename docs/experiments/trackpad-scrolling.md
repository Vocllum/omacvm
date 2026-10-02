# Experiment: two-finger scrolling through OmacVM Gestures

Branch `experiment/trackpad-scrolling`. Nothing here is on `main` until a
decision is made. Tested on the production Parallels VM (Omarchy 4.0.3rc4,
Hyprland 0.56.2, libinput 1.32.0, Chromium 153) on a MacBook Pro M4 Max,
macOS 15.7.4, Parallels Desktop 27.0.2.

## Goal

OmacVM Gestures' 3/4-finger swipes and pinch feel more responsive than
Parallels' own smooth scrolling. Try the same for two-finger scrolling, in all
directions, so that only one-finger pointer movement (and clicks) still come
from Parallels.

## Test log (2026-10-02)

### 1. Raw two-finger touches to the virtual touchpad

`omacvm-gestures --scroll`: every two-finger frame goes to the guest's virtual
Apple touchpad (not only pinches); macOS's scroll events from the built-in
trackpad, momentum included, are dropped so Parallels does not scroll as well.
libinput turns the touches into touchpad scrolling.

- Panning in every direction while zoomed in (Chromium): **excellent**.
- Normal scrolling: far too sensitive and accelerated; small inputs keep
  scrolling for about a second.

Guest touchpad settings at the time (Omarchy defaults): natural scrolling on,
tap-to-click off, scroll factor 0.4, adaptive acceleration.

### 2. Flat acceleration, scroll factor 0.25 for the virtual touchpad

`hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", accel_profile = "flat", scroll_factor = 0.25 })`

- Files (GTK): very close to macOS; long scrolls a bit slow.
- Chromium: still overshoots, gliding on for about a second.

Recording in the guest (evdev, timestamps) of a few short scrolls:

- Parallels' virtual mouse sent **no** scroll events: no double scrolling.
- Finger frames arrive evenly every 8 ms (125 Hz), no bursts; the touches end
  0.1-0.15 s after a short push. The overshoot happens after the last frame:
  it is **Chromium's own fling** (and its fling booster, which speeds up
  repeated swipes in the same direction). Chromium has no switch to tune it
  (`ExperimentalFlingAnimation` was tried and made it worse).

### 3. Custom acceleration curves (`scroll_points`)

A macOS-like curve (1:1 slow, up to 1.5x fast) for scrolling. Everything,
4-finger swipes included, became 3-5x too sensitive: libinput slows touchpad
motion by 0.297 ("magic slowdown") only in its built-in profiles; a custom
curve bypasses it. Rescaled by 0.297: still too sensitive overall. Reverted.

### 4. macOS's own scroll physics, replayed as a high-resolution wheel

`omacvm-gestures --scroll` (current branch code): macOS's continuous scroll
events (trackpad, Magic Mouse; macOS's acceleration and momentum included)
go to the guest as point deltas (`W <dx> <dy>`), and the guest replays them on
a virtual high-resolution wheel, "OmacVM scroll (macOS)" (120 units per
`OMACVM_SCROLL_POINTS_PER_DETENT` points, default 40). Two-finger touches go
to the virtual touchpad only for pinch again. A wheel mouse still scrolls
through Parallels. The virtual touchpad's test settings were removed.

- 3- and 4-finger swipes: almost perfect.
- Files: fine, a bit nervous and fast.
- Chromium: still glides too much (now its smooth-scrolling animation of
  wheel steps, on top of macOS's momentum).
- Chromium pinch zoom: works well.
- Chromium pinch zoom, then two-finger panning: the worst, very buggy (when
  zoomed in, Chromium pans smoothly only with touchpad scrolling, not a wheel).

### 5. Chromium without smooth scrolling, slower wheel (in progress)

`--disable-smooth-scrolling` in `~/.config/chromium-flags.conf`;
`OMACVM_SCROLL_POINTS_PER_DETENT=60` (systemd drop-in
`/etc/systemd/system/omacvm-gestures.service.d/scroll-test.conf`).

- Chromium (with the flag): **very nice**, very close to macOS; slightly less
  clean than macOS's 120 Hz scrolling.
- Google Chrome reads its own `~/.config/chrome-flags.conf`, still had smooth
  scrolling on: glides too much.
- Pinch-zoomed page, two-finger panning: **impossible** with the wheel, in
  Chrome (expected in any Chromium-based browser: a wheel does not pan the
  zoomed viewport).

### 6. macOS's physics replayed as two virtual fingers (in progress)

`OMACVM_SCROLL_MODE=touch` in the guest (`wheel` stays the alternative):
macOS's deltas move two virtual fingers on the virtual touchpad
(`OMACVM_SCROLL_TOUCH_SCALE` touchpad units per point, start 4; the touchpad
is 100 units per mm), held down through macOS's momentum and lifted 60 ms
after the last delta, when the movement has died down. Near the touchpad's
edge they hold still for three frames, lift and start again in the middle.
Real finger frames (pinch, 3/4-finger swipes) take over the touchpad. Chrome
also got `--disable-smooth-scrolling` (original in
`chrome-flags.conf.before-omacvm-scroll-test`).

- **Very good**: Chrome and Chromium very close to macOS, zoomed panning works.
- Very small, slow scrolling (almost per pixel) does not respond, like a dead
  zone in the middle; macOS reacts there. Cause: libinput starts a two-finger
  scroll only after some movement, and with 60 ms the virtual fingers lifted
  in every pause of slow scrolling, so each small step had to cross that
  threshold again.

### 7. Virtual fingers stay down through pauses (in progress)

`OMACVM_SCROLL_TOUCH_HOLD` (default now 0.5 s): the fingers lift only after
half a second without scrolling, so slow, fine scrolling runs in one touch.
They are still by then, so lifting starts no fling.

- Very good, but really slow movement (about 1 mm/s) is still less sensitive
  than macOS: Chrome skips input.

Recording (guest: the received deltas, `libinput debug-events` on the virtual
touchpad): macOS sends slow scrolling as whole 1-point steps every 4-20 ms,
some of them sideways (macOS does that for its own apps too). libinput passes
**every** step on: a 1-point step becomes a finger scroll of 0.42, nothing is
swallowed. After the compositor's touchpad factor (0.4) a slow step reaches
Chrome as a fraction of a pixel, and Chrome drops part of such amounts.

### 8. Low-speed boost (in progress)

`OMACVM_SCROLL_SLOW_BOOST` (default 1.0): steps below 3 points get extra
movement, 1 -> 2, 2 -> 2.5, 3 and more unchanged (additive, so it always
rises with the input). Normal and fast scrolling stay exactly as macOS sends it.

- Worse: coarser, no more per-pixel scrolling. Boost off again (0).

Logging both of macOS's scroll fields and NSEvent's `scrollingDeltaY` (what
macOS's own apps use) in OmacVM Gestures: during slow scrolling all of them
carry **whole points only** (the fixed-point field is 0 for small movements).
macOS's scroll events have no finer data; macOS shows its 1-point steps at
120 Hz, 1 point = 1 pixel.

### 9. Hybrid: raw fingers while touching, macOS's momentum after (in progress)

Mac (`--scroll`): two-finger frames go to the guest as raw touches again; while
two fingers touch the built-in trackpad, macOS's scroll events are dropped;
after the lift only macOS's momentum goes, as `W` deltas. Other continuous
scrolling (Magic Mouse) still goes as `W` as a whole.

Guest (`OMACVM_SCROLL_MODE=touch`): the virtual fingers follow the raw
positions (hundredths of a millimetre). When two fingers lift, they stay down
for up to 0.15 s waiting for momentum; macOS's momentum then moves them on,
scaled so that the speed at the hand-over matches the fingers' last speed
(units/s against points/s of the first momentum steps); they lift 0.5 s after
the momentum has died down. Touchpad scroll factor for the virtual trackpad:
0.25 (acceleration stays the default, which suits the 3/4-finger swipes).

- **Overall awesome, at the macro level better than macOS.** Fast scrolling
  jumps and skips.
- Cause: Hyprland's log shows libinput's "kernel bug: Touch jump detected and
  discarded" for the virtual trackpad (40 times). Hand-over scales were 3-21
  touchpad units per point and momentum steps up to 45 points: several
  millimetres in one frame, which libinput drops as a jump. Long glides also
  ran off the 156 x 96 mm virtual touchpad.

### 10. Momentum in small, evenly timed steps; room for the glide (in progress)

- Momentum steps are queued and applied every 4 ms, at most 2 mm per step
  (a few milliseconds of extra delay in the glide only; the fingers stay direct).
- The virtual touchpad is 1 x 1 m; the real trackpad maps onto its middle
  156 x 96 mm, so fingers, pinch and swipes feel the same and a glide has room.
- At the edge the fingers stop and lift after the hold instead of letting go.

- Macro level great; no new touch-jump warnings (still 40): the skipping is
  gone.
- Long scrolling (several flicks in a row) often jumps back. Cause: fingers
  touching down during a glide reuse the trackpad's contact ids, so the new
  touch continued the glide's virtual touch and leapt back from where the
  glide had got to.

### 11. A new touch ends the glide's touch first (in progress)

When real fingers touch down while a glide runs, the glide's virtual fingers
lift first (pending momentum dropped), and the real fingers start a fresh touch.

- No more jumping back.
- Random pinch zooms while scrolling: raw fingers never keep their spacing
  exactly, and libinput sometimes reads the change as a pinch.
- Resting two fingers makes the page shiver: finger jitter of fractions of a
  millimetre, now passed on precisely, scrolls back and forth.

### 12. Scroll stays scroll, jitter filtered (in progress)

Guest, two-finger touches: the spacing is fixed at touch-down and only the
centre moves, through a One Euro filter (`OMACVM_SCROLL_FILTER`, min cutoff
1.5 Hz, beta 0.1, in millimetres: strong smoothing when still or slow, almost
none when fast). A clear spread (`OMACVM_SCROLL_PINCH_MM`, 6 mm, and more than
the centre has moved) switches the touch to raw fingers: a pinch.

- Much better. Still: random pinch zooms when scrolling slowly and carefully
  (the fingers drift apart a few millimetres over a long touch, and the
  accumulated spread looked like a pinch), and going from very slow to
  medium speed accelerates a bit too much (libinput's adaptive acceleration on
  the virtual touchpad).

### 13. Pinch is macOS's decision; flat acceleration (in progress)

- Mac: when macOS recognizes a pinch (NSEventTypeMagnify, which the event tap
  already sees and drops), the helper sends `P`; the guest switches the
  current two-finger touch to raw fingers only then. The spread-based guess is
  off (`OMACVM_SCROLL_PINCH_MM=0`).
- Guest: `accel_profile = "flat"` for the virtual trackpad again (scroll
  factor 0.25). To watch: whether 3/4-finger swipes still feel right with flat.
- Question from the test: take over the Mac's trackpad settings? Already: the
  pointer (macOS's cursor via Parallels) and the glide (macOS's momentum,
  macOS's scroll direction). Not yet: while the fingers touch, Omarchy's own
  natural-scrolling setting and speed apply. Candidate: read macOS's natural
  scrolling and Accessibility scrolling speed and set them for the virtual
  trackpad.

- Good overall, but still too fast; 3/4-finger swipes awesome with flat.
- Pinch zoom no longer works: macOS's signal arrives (logged), but libinput
  never turns a touch it already treats as a scroll into a pinch.
- To tidy: the helper sends `P` many times per pinch (229 log lines);
  harmless, the guest ignores repeats.

### 14. Pinch restarts the touch; slower (in progress)

- On `P` the guest lifts the virtual fingers and puts them down again with the
  raw positions: a new touch whose fingers spread, which libinput reads as a
  pinch from the start.
- Scroll factor for the virtual trackpad 0.18 (was 0.25); the glide follows,
  being matched to the finger speed.

Results: pending.

## Candidate if the wheel cannot pan a zoomed page

Replay macOS's physics as **touchpad** movement instead of wheel steps: move
two virtual fingers on the virtual touchpad by macOS's scroll deltas, keep them
down through macOS's momentum and lift only when it has died down. Apps then
get touchpad scrolling (Chromium pans a zoomed page properly), but with near
zero speed at the lift, so Chromium and GTK add no fling of their own.

## Test changes on the production VM (to revert or adopt)

- `/usr/local/bin/omacvm-gestures`: this branch's guest daemon.
- `/etc/systemd/system/omacvm-gestures.service.d/scroll-test.conf`
  (`OMACVM_SCROLL_MODE`, `OMACVM_SCROLL_TOUCH_SCALE`,
  `OMACVM_SCROLL_POINTS_PER_DETENT`).
- `~/.config/chromium-flags.conf` and `~/.config/chrome-flags.conf`:
  `--disable-smooth-scrolling` added (originals in
  `*-flags.conf.before-omacvm-scroll-test`).
- `~/.config/hypr/input.lua`: test block removed again (original in
  `input.lua.before-omacvm-scroll-test`).
- `/root/.ssh/authorized_keys`: the current `omacvm` key added (kept).
- Mac: OmacVM Gestures installed with `--scroll` (back:
  `src/gestures/mac/install.sh`).
