# omaparallels-bridge

Gives the Omarchy VM in Parallels what it can't see by itself: the Mac's
**Wi-Fi** (the VM only has a virtual Ethernet NIC), the Mac's **audio devices
and volume**, and the **media keys** (volume, display brightness, keyboard
backlight) while the VM is full screen. A small Swift agent app on the Mac
serves JSON over HTTP on the Parallels network and pushes changes as
Server-Sent Events, so the VM's status bar can show a real Wi-Fi icon and its
own volume/brightness popups.

| Part | Where |
|---|---|
| Mac helper | `mac/*.swift` → `~/Applications/OmaparallelsBridge.app` (agent app, no Dock icon, menu-bar icon, ad-hoc signed, `org.omaparallels.bridge`). LaunchAgent `org.omaparallels.bridge` starts it at login |
| Listens on | `http://10.211.55.2:47831`: the Mac's address on the Parallels shared network (`bridge101`), **never** `0.0.0.0`. (The Mac is `.2`, not `.1`.) It waits for that address if Parallels isn't running, and re-binds when the bridge comes back or after wake |
| Token | Mac: `~/Library/Application Support/omaparallels-bridge/token` (0600, created on first run). VM: `/home/<user>/.config/omaparallels-bridge/token` (0600, owned by the desktop user) |
| Config | `~/Library/Application Support/omaparallels-bridge/config.json`: `capture_keys`, `menu_bar_icon` |
| Log | `tail -f ~/Library/Logs/omaparallels-bridge.log` |
| Guest CLI | `guest/omaparallels-bridge` → `/usr/local/bin/omaparallels-bridge` (bash + curl) |
| Guest installer | `guest/install.sh <user>` (root, in the VM): installs the CLI, the OSD service and every Omarchy shell plugin in `guest/omarchy-plugins/<id>/`. `mac/push-guest.sh` copies `guest/` over and runs it, so one command from the Mac reproduces the whole guest side |
| Guest OSD | `guest/omaparallels-bridge-osd` → `/usr/local/bin/omaparallels-bridge-osd`, user service `omaparallels-bridge-osd` (`guest/omaparallels-bridge-osd.service`). Follows `/events` and shows Omarchy's own OSD (`omarchy-osd`) for the Mac's volume, mute, brightness and keyboard-light changes |

No third-party dependencies. It uses only Apple frameworks: CoreWLAN, CoreLocation, CoreAudio,
AppKit, plus the private DisplayServices and CoreBrightness frameworks for brightness.

## Install

```bash
# on the Mac
tools/omaparallels-bridge/mac/install.sh            # build, sign, install, start (asks for Location + Accessibility)
tools/omaparallels-bridge/mac/push-guest.sh root@10.211.55.4 gillesgoetsch   # token, CLI, OSD service into the VM
#   SSH_OPTS="-i ~/.ssh/omarchy-parallels" for a specific key
# in the VM
omaparallels-bridge state
```

## Permissions

| Permission | Why | Grant / revoke |
|---|---|---|
| **Location Services** | macOS only reveals SSIDs and BSSIDs to apps with location access. No location is ever read. Without it, `ssid`/`bssid` are `null` and scans return no names (`location_authorized: false`) | Prompt on first start. System Settings › Privacy & Security › Location Services › Omaparallels Bridge (toggle). |
| **Accessibility** | The active event tap that swallows media keys while the VM is full screen. Without it, everything else works and the keys stay with macOS | Prompt on first start. System Settings › Privacy & Security › Accessibility › Omaparallels Bridge. Revoke: toggle off, or `tccutil reset Accessibility org.omaparallels.bridge` |

Audio and Wi-Fi state need no other permission. The menu-bar icon shows both
grants. Click an entry to open its settings pane.

**Re-grant after every rebuild** of the Mac helper. The signature is ad-hoc, so
each build is a new binary to TCC. Location re-grants by itself (observed on macOS
15.7). Accessibility does not: run `tccutil reset Accessibility
org.omaparallels.bridge`, restart the helper (`launchctl kickstart -k
gui/$(id -u)/org.omaparallels.bridge`), and allow it again. Building with a real
identity (`SIGN_IDENTITY="Apple Development: …" ./install.sh`) avoids this.

## API

Every request needs `Authorization: Bearer <token>`. Missing or wrong token → `401`.
Responses are JSON. Errors are `{"error": "…"}`.

```bash
T=$(cat ~/.config/omaparallels-bridge/token); B=http://10.211.55.2:47831
curl -H "Authorization: Bearer $T" $B/state
```

### `GET /state`: Wi-Fi

```json
{"interface":"en0","power":true,"connected":true,"location_authorized":true,
 "ssid":"TF-Office","bssid":"c4:b3:01:dc:fa:3b","rssi":-50,"noise":-93,"snr":43,"quality":66,
 "channel":{"number":36,"band":"5GHz","width_mhz":80},"security":"wpa2-personal","secure":true,
 "tx_rate_mbps":866,"phy_mode":"802.11ac","country_code":"CH","seq":3,"updated_at":"2026-10-01T11:14:33Z"}
```

- Not connected or Wi-Fi off: all link fields are `null`.
- `connected: true` with `ssid: null` means Location Services is missing.
- `quality` is 0–100 from RSSI: −90 dBm = 0, −30 dBm = 100. Map it to the 4 bar icons.
- `band` is `2.4GHz` / `5GHz` / `6GHz`.
- `security` is one of `open`, `wep`, `wpa-personal`, `wpa2-personal`, `wpa2-wpa3-personal`, `wpa3-personal`, `owe`, `owe-transition`, `*-enterprise`, `unknown`.

### `GET /scan` and `GET /scan?cached=1`: nearby networks

```bash
curl -H "Authorization: Bearer $T" "$B/scan?cached=1"
```

- **Without `cached`:** an active radio scan (2–4 s). A scan younger than 10 s is reused (`"source": "recent-scan"`).
- **With `cached=1`:** macOS's own scan cache, returned instantly. Use it for opening the network menu.

There is one entry per SSID (the strongest BSSID). The current network comes first, the rest are sorted by RSSI. Hidden networks are left out.

```json
{"count":9,"source":"cache","scanned_at":"…","location_authorized":true,"networks":[
  {"ssid":"TF-Office","bssid":"c4:b3:01:dc:fa:3a","rssi":-46,"noise":-93,"quality":73,
   "channel":{"number":11,"band":"2.4GHz","width_mhz":20},"bands":["2.4GHz","5GHz"],
   "security":"wpa2-wpa3-personal","secure":true,"known":true,"current":true}, …]}
```

- `known` means the network is saved in the Mac's preferred networks. Reading that list needs no admin rights.
- `noise` is `null` when the scan didn't measure it.
- When Wi-Fi is off, the scan returns `503 {"error":"Wi-Fi is off"}`.

### `GET /audio`: audio state

```json
{"output":{"uid":"BuiltInSpeakerDevice","name":"MacBook Pro Speakers","transport":"built-in",
           "volume":0.562,"muted":false,"has_volume":true,"volume_settable":true,"has_mute":true,
           "has_output":true,"has_input":false,"default_output":true,"default_input":false},
 "input":{"uid":"BuiltInMicrophoneDevice","name":"MacBook Pro Microphone","volume":0.54,"muted":false,…},
 "devices":[{"uid":"…","name":"…","transport":"bluetooth","has_output":true,"has_input":true,
             "default_output":false,"default_input":false}, …],
 "seq":7,"updated_at":"…"}
```

- `volume` is 0–1 and is the same value as the macOS menu-bar slider.
- A device without volume or mute control (typically HDMI or DisplayPort) reports `"has_volume": false` and `"volume": null` instead of failing.
- `transport` is one of `built-in`, `usb`, `bluetooth`, `bluetooth-le`, `hdmi`, `displayport`, `airplay`, `thunderbolt`, `pci`, `virtual`, `aggregate`, `continuity`, `unknown`.

### Audio control

All four endpoints take a JSON body. Each answers with the new `/audio` state and also pushes it on `/events`.

```bash
H=(-H "Authorization: Bearer $T" -H 'Content-Type: application/json')
curl "${H[@]}" -d '{"volume": 0.4}'              $B/audio/volume   # absolute 0..1
curl "${H[@]}" -d '{"delta": 0.05}'              $B/audio/volume   # relative (+5 %), raising unmutes
curl "${H[@]}" -d '{"delta": -0.05}'             $B/audio/volume
curl "${H[@]}" -d '{"volume": 0.6, "scope": "input"}' $B/audio/volume   # microphone
curl "${H[@]}" -d '{"muted": "toggle"}'          $B/audio/mute     # or true / false; "scope": "input" too
curl "${H[@]}" -d '{"uid": "BuiltInSpeakerDevice"}'   $B/audio/output
curl "${H[@]}" -d '{"uid": "BuiltInMicrophoneDevice"}' $B/audio/input
```

The endpoints return these errors:

- `400` for a bad body.
- `404` for an unknown UID.
- `409` when the device has no volume or mute control.

When you switch the output, macOS sound effects follow it, but only if they were playing through the previous default (the same as the menu bar).

The guest CLI wraps all of this:

```bash
omaparallels-bridge volume +5
omaparallels-bridge mute
omaparallels-bridge mic-volume 60
omaparallels-bridge output <uid>
```

Hyprland volume keys could call it like this:
`bindel = , XF86AudioRaiseVolume, exec, omaparallels-bridge volume +5`.

### `GET /events`: push (Server-Sent Events)

```bash
curl -N -H "Authorization: Bearer $T" $B/events
```

On connect you get the current `wifi` and `audio` state. After that:

| event | when | data |
|---|---|---|
| `wifi` | Wi-Fi power, SSID, BSSID, link, mode or country changed (CoreWLAN events, sent within ~0.3 s); RSSI etc. re-read every 5 s | same as `GET /state` |
| `audio` | default device, volume, mute or the device list changed (CoreAudio listeners, e.g. AirPods connect) | same as `GET /audio` |
| `scan` | an active scan finished, or macOS refreshed its scan cache (at most every 10 s) | same as `GET /scan` |
| `osd` | volume, mute, brightness or keyboard light changed | `{"type":"osd","kind":"volume"\|"mute"\|"brightness"\|"keyboard","value":0-100,"muted":bool,"source":"keys"\|"api"\|"external","device":"MacBook Pro Speakers","at":"…"}` |

A `wifi` or `audio` event is only sent when something changed. `seq` counts the changes per feed.

The `source` field on `osd` events tells the VM where a change came from:

- **`keys`:** a media key caught while the VM was full screen.
- **`api`:** a `POST` from the VM.
- **`external`:** anything else (the macOS slider, keys while the VM wasn't full screen, AirPods). A device switch does not count as an external volume change.
- Keyboard-light events only ever come from caught keys.

External brightness changes are polled every 0.5 s while a client is connected. Only jumps of 2 or more points count, so slow auto-brightness drift stays quiet.

Other details:

- A `: ping` comment is sent every 15 s when nothing else was sent.
- `retry: 3000` tells EventSource clients to reconnect after 3 s.
- Up to 16 clients can connect at once.

`POST /power`, `/join` and `/disconnect` answer `501` for now (stage 2).

## Media keys

When **Parallels Desktop is frontmost and its VM window covers a whole display**, the helper catches these keys:

- volume up/down and mute
- display brightness up/down
- keyboard backlight up/down/toggle

The tap swallows them, key-up included, so macOS shows no popup. The helper applies the change itself and pushes an `osd` event for the VM's own popup. Every other event passes through untouched, and so does every key while the VM isn't full screen. The full-screen check is the same as `trackpad-bridge`'s.

How each key is handled:

- **Volume and mute:** CoreAudio, on the current default output, in 1/16 steps like macOS. **Shift+Option** gives quarter steps (1/64). Any volume key unmutes.
- **Brightness:** DisplayServices (private), on the built-in display, also in 1/16 or 1/64 steps.
- **Keyboard backlight:** CoreBrightness `KeyboardBrightnessClient` (private). M-series MacBook Pros have no backlight keys on the built-in keyboard; the codes only come from external keyboards that have them.

A key passes through to macOS when the helper can't apply it, for example on an output without volume control, or for brightness with the lid closed.

The VM never sees a swallowed key, so Omarchy's own key bindings (`omarchy-audio-output-volume` and its OSD) don't run. Instead, `omaparallels-bridge-osd` in the VM turns the `osd` events into `omarchy-osd -i volume-high|volume-muted|brightness|keyboard -p <value>`. That is the native Omarchy popup, showing the Mac's value. By default it reacts to `keys` and `api` changes. Set `OMAPARALLELS_BRIDGE_OSD_SOURCES="keys api external"` in the service to also show changes made on the Mac outside the VM. Check it with `systemctl --user status omaparallels-bridge-osd`.

To turn capture off, use either of these:

- The menu-bar icon (keyboard symbol) › **Send Media Keys to Full-Screen VM**. The icon dims while it's off, and the setting is saved.
- `"capture_keys": false` in `config.json`, then restart the helper.

**Quit** in the menu stops the helper until the next login. The LaunchAgent only restarts it after a crash.

macOS's own volume popup can't be triggered on demand. `OSDManager`'s
`showImage:…` (private OSD.framework) is gone in macOS 15. That's why the VM draws its own.

## Robustness (tested 2026-10-01, macOS 15.7.4, Parallels 27.0.2)

- **Wi-Fi off/on:** the VM's `/events` stream stayed connected throughout:
  - `power:false` arrived 1 s after switching off.
  - `power:true` and then `connected:true, ssid:TF-Office` arrived ~7 s after switching on.
  - While Wi-Fi was off, the API on 10.211.55.2 kept answering even though the VM had no internet.
- **Sleep/wake:** on wake the helper re-subscribes to CoreWLAN, re-binds the listener, and re-reads all state after 2 s and 10 s. The 5 s tick and the listener check also recover anything missed. Check the log for `system woke up`.

## Stage 2 (designed, not built): Wi-Fi control

| Endpoint | Body | Implementation |
|---|---|---|
| `POST /power` | `{"on": bool}` | `CWInterface.setPower(_:)`. No admin rights needed |
| `POST /join` | `{"ssid": "…", "password": "…"?}` | Find the network in a fresh scan (`scanForNetworks(withName:)`), then `associate(to:password:)`. For a saved network, call it with `nil` and the system takes the password from the keychain. If that fails without a password, fall back to `networksetup -setairportnetwork en0 <ssid>` |
| `POST /disconnect` | – | `CWInterface.disassociate()` |

- **The VM's internet runs over the Mac's Wi-Fi.** `power off`, `disconnect` or joining a dead network cuts the VM off the internet. The Parallels link (10.211.55.x) is local and keeps working, as the off/on test shows, so the API stays usable to turn Wi-Fi back on. The endpoints should answer right away, then act, so the response doesn't race the change.
- "Forget network" is left out because it needs admin rights.
- If *System Settings › Wi-Fi › Advanced › Require administrator authorization* is on for turning Wi-Fi on/off or changing networks, these calls fail with an authorization error. Map that to `403`.
- Every control call should be logged with the caller's IP.

## Uninstall

```bash
tools/omaparallels-bridge/mac/uninstall.sh           # stop, remove LaunchAgent + app, reset Accessibility
tools/omaparallels-bridge/mac/uninstall.sh --purge   # … and delete token, config, log
# Location Services: System Settings › Privacy & Security › Location Services: remove Omaparallels Bridge if still listed
# in the VM:
ssh root@10.211.55.4 'systemctl --user -M gillesgoetsch@ disable --now omaparallels-bridge-osd
  rm -rf /home/gillesgoetsch/.config/omaparallels-bridge /usr/local/bin/omaparallels-bridge /usr/local/bin/omaparallels-bridge-osd \
         /etc/systemd/user/omaparallels-bridge-osd.service'
```
