# OmacVM lock

Makes the Mac's lock look like Omarchy's: the current Omarchy theme follows to
macOS.

- **Wallpaper / lock-screen background**: the Omarchy theme's background
  becomes the Mac wallpaper on every display; macOS 14+ shows the wallpaper on
  the lock screen.
- **OmarchyLock.saver**: a screen saver that draws Omarchy 4's lock screen
  (`/usr/share/omarchy/shell/plugins/lock/LockView.qml`): background aspect-filled
  and heavily blurred (MultiEffect blurMax 128 x 1.25, contrast -0.08), the
  381x67 password card with a 3 px border, radius = Hyprland rounding,
  "Enter Password" in the monospace font at heading x 1.125 — colours from the
  theme's `shell.toml [lock]`. With "require password immediately" this is what
  the locked Mac shows; the moment you type, macOS's own password UI takes over
  (that part cannot be themed).

Theme switches (and background switches) in the VM propagate automatically.

| Part | Where |
|---|---|
| Guest exporter | `guest/omarchy-theme-export` → `/usr/local/bin`; user units `omarchy-theme-export.{service,path}` (path watches `~/.local/state/omarchy/current`). Writes `background-<hash>.png`, `font.ttf`, `theme.json` to the shared folder `theme` (`/mnt/psf/theme` = Mac `~/.local/share/omacvm/theme`) |
| Mac sync | `mac/theme-sync` + `mac/set-wallpaper.swift` → `~/Library/Application Support/OmarchyLock/`; LaunchAgent `org.omacvm.lock` (WatchPaths on `theme.json`), log `~/Library/Logs/omacvm-lock.log` |
| Screen saver | `saver/OmarchyLockView.m` → `~/Library/Screen Savers/OmarchyLock.saver` (theme data copied into its Resources, re-signed ad-hoc; the saver runs sandboxed and only reads its bundle). `saver/render-test.m` renders it to a PNG for checks |

Install: `mac/install.sh` (Mac), `guest/install.sh <user>` (VM, root).
Remove: `mac/uninstall.sh` (the wallpaper stays as it is).

One-time macOS settings (not scriptable): Screen Saver → Omarchy Lock;
Lock Screen → require password *immediately*; optionally hide the large clock.
