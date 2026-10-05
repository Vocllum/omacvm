// Offline tests of keys-model.swift (when the media-key tap is created again)
// and wifi-model.swift (a steady Wi-Fi state). No permissions, no Wi-Fi.
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1; print("     (line \(line))") }
}

// ---- TapRearm ----
var r = TapRearm()
check(!r.front(nil), "tap: no OmacVM in front, nothing to do")
check(r.front(600), "tap: an OmacVM VM comes to the front: again")
check(!r.front(600) && !r.front(600), "tap: not again while it stays in front (checked every 2 s)")
check(r.front(700), "tap: straight to a second VM (another QEMU): again")
check(!r.front(nil) && r.front(700), "tap: the same VM after another app: again")
check(!r.front(nil) && r.front(800), "tap: OmacVM.app restarted (a new pid): again")
check(r.failed() && !r.failed() && !r.failed(), "tap: a failed re-creation is logged once")
r.worked()
check(r.failed(), "tap: ... and again after one worked")

// ---- WiFiSteady ----
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0 + s }
func wifi(_ connected: Bool, ssid: String? = "Office", rssi: Int = -60, power: Bool = true, location: Bool = true) -> [String: Any] {
  ["connected": connected, "power": power, "ssid": connected ? (ssid as Any) : NSNull(),
   "rssi": connected ? rssi : NSNull() as Any, "location_authorized": location, "wired": true]
}
func connected(_ s: [String: Any]) -> Bool { s["connected"] as? Bool == true }

var w = WiFiSteady()
check(!connected(w.take(wifi(false), link: false, event: nil, now: at(0)).state), "wifi: not connected from the start is reported")
var r1 = w.take(wifi(true), link: true, event: nil, now: at(1))
check(connected(r1.state) && !r1.held, "wifi: connected")
// The Mac mini's flicker: a lone bad read at a tick, link still up, then fine.
r1 = w.take(wifi(false), link: true, event: nil, now: at(6))
check(connected(r1.state) && r1.held && r1.state["ssid"] as? String == "Office", "wifi: a bad read while the link is up keeps the last state")
r1 = w.take(wifi(true, rssi: -62), link: true, event: nil, now: at(11))
check(connected(r1.state) && !r1.held && r1.state["rssi"] as? Int == -62, "wifi: the next good read goes through")
// Ticks every 5 s: bad, good, bad, good (link up): never a change.
var flips = 0, last = true
for k in 0..<12 {
  let s = w.take(wifi(k % 2 == 1), link: true, event: nil, now: at(20 + Double(k) * 5)).state
  if connected(s) != last { flips += 1; last = connected(s) }
}
check(flips == 0, "wifi: alternating good and bad reads report no change (\(flips) flips)")
// Link state not known (no SCDynamicStore answer): held for WiFiSteady.hold, then believed.
r1 = w.take(wifi(false), link: nil, event: nil, now: at(100))
check(connected(r1.state) && r1.held, "wifi: a lone bad read without a link state is held")
r1 = w.take(wifi(true), link: nil, event: nil, now: at(105))
check(connected(r1.state) && !r1.held, "wifi: ... and the hold ends with a good read")
_ = w.take(wifi(false), link: false, event: nil, now: at(200))
r1 = w.take(wifi(false), link: false, event: nil, now: at(205))
check(connected(r1.state) && r1.held, "wifi: no event: still held after 5 s")
r1 = w.take(wifi(false), link: false, event: nil, now: at(210))
check(!connected(r1.state) && !r1.held, "wifi: no event: believed after \(Int(WiFiSteady.hold)) s")
// A real disconnect: CoreWLAN's event comes with it, so it is shown at once.
_ = w.take(wifi(true), link: true, event: at(209), now: at(300))
r1 = w.take(wifi(false), link: false, event: at(400), now: at(400.3))
check(!connected(r1.state) && !r1.held, "wifi: a disconnect with a CoreWLAN event is shown at once")
_ = w.take(wifi(true), link: true, event: at(400), now: at(500))
r1 = w.take(wifi(false), link: false, event: at(499), now: at(500.5))
check(!connected(r1.state), "wifi: an event just before the drop counts too")
_ = w.take(wifi(true), link: true, event: at(500), now: at(600))
r1 = w.take(wifi(false), link: false, event: at(560), now: at(605))
check(connected(r1.state) && r1.held, "wifi: an old event does not count")
// Wi-Fi switched off: the power event says so.
_ = w.take(wifi(true), link: true, event: at(500), now: at(700))
r1 = w.take(wifi(false, power: false), link: false, event: at(710), now: at(710.3))
check(!connected(r1.state) && r1.state["power"] as? Bool == false, "wifi: power off is shown at once")
// While held, the fields that are no part of the link come from the newest read.
_ = w.take(wifi(true), link: true, event: nil, now: at(800))
r1 = w.take(wifi(false, location: false), link: true, event: nil, now: at(805))
check(connected(r1.state) && r1.state["location_authorized"] as? Bool == false, "wifi: Location Services from the newest read while held")

// Bad reads only, for a minute, while the link still says up: believed then.
_ = w.take(wifi(true), link: true, event: nil, now: at(900))
r1 = w.take(wifi(false), link: true, event: nil, now: at(905))
check(connected(r1.state) && r1.held, "wifi: link up, a bad read: held")
r1 = w.take(wifi(false), link: true, event: nil, now: at(950))
check(connected(r1.state) && r1.held, "wifi: link up, bad reads for 45 s: still held")
r1 = w.take(wifi(false), link: true, event: nil, now: at(966))
check(!connected(r1.state) && !r1.held, "wifi: link up, only bad reads for \(Int(WiFiSteady.linkHold)) s: believed")
// ... but one good read in between starts the minute again.
_ = w.take(wifi(true), link: true, event: nil, now: at(1000))
_ = w.take(wifi(false), link: true, event: nil, now: at(1005))
_ = w.take(wifi(true), link: true, event: nil, now: at(1040))
r1 = w.take(wifi(false), link: true, event: nil, now: at(1070))
check(connected(r1.state) && r1.held, "wifi: a good read between restarts the minute")

// ---- MediaRoute: where each media key goes ----
func route(_ k: MediaKey, _ vm: FrontVM?, volume: Bool = true, mute: Bool = true, mac: UInt32? = nil,
           external: ExternalState = .unknown, light: Bool = false) -> KeyRoute {
  MediaRoute.route(k, vm: vm, volumeSettable: volume, muteSettable: mute, macBrightness: mac, external: external, keyboardLight: light)
}
// A Mac mini M4 with ONE display, an LG UltraFine 5K (display 5, external, set
// through DisplayServices), no built-in display, no keyboard light; audio
// through a Focusrite Scarlett 2i2 (no software volume, no mute).
let uf: UInt32 = 5
let miniFull = FrontVM(omacvm: true, fullScreen: true, display: uf, builtin: false, vmKeys: true)
let miniWin = FrontVM(omacvm: true, fullScreen: false, display: uf, builtin: false, vmKeys: true)
for (vm, how) in [(miniFull, "full screen"), (miniWin, "windowed")] {
  check(route(.brightnessUp, vm, mac: uf, external: .works) == .external(uf), "mini \(how): brightness sets the UltraFine (its own control)")
  check(route(.brightnessDown, vm, mac: uf, external: .unknown) == .mac,
        "mini \(how): not looked at yet: the Bridge's own call on the same display (never dropped)")
  check(route(.brightnessUp, vm, mac: uf, external: .off) == .mac, "mini \(how): external brightness off: still the UltraFine")
  check(route(.volumeUp, vm, volume: false, mute: false) == .vm("volumeup"), "mini \(how): Scarlett, volume up: the VM's own volume")
  check(route(.volumeDown, vm, volume: false, mute: false) == .vm("volumedown"), "mini \(how): Scarlett, volume down: the VM's")
  check(route(.mute, vm, volume: false, mute: false) == .vm("audiomute"), "mini \(how): Scarlett, mute: the VM's")
  check(route(.volumeUp, vm) == .mac && route(.mute, vm) == .mac, "mini \(how): speakers with a volume: the Mac's")
  check(route(.play, vm) == .vm("audioplay") && route(.next, vm) == .vm("audionext") && route(.previous, vm) == .vm("audioprev"),
        "mini \(how): play/pause, next, previous: the VM's players")
  check(route(.fast, vm) == .vm("audionext") && route(.rewind, vm) == .vm("audioprev"), "mini \(how): an Apple keyboard's track keys too")
  check(route(.keyboardUp, vm) == .macOS(nil), "mini \(how): no keyboard light: macOS's")
}
// The UltraFine says no (asleep): to macOS with the reason, and the Bridge's own call when it reaches it.
check(route(.brightnessUp, miniWin, mac: nil, external: .no("asleep")) == .macOS("asleep"), "mini: cannot be set: to macOS, with why")
check(route(.brightnessUp, miniWin, mac: uf, external: .no("asleep")) == .mac, "mini: no DDC but DisplayServices reaches it: the Bridge's")
// No VM in front: everything stays macOS's.
for k in [MediaKey.volumeUp, .mute, .play, .brightnessUp, .keyboardUp] {
  check(route(k, nil, volume: false, mac: uf, external: .works, light: true) == .macOS(nil), "no VM in front: \(k) is macOS's")
}
// The VM takes no keys (its control socket not found): to macOS, with why.
var noKeys = miniWin; noKeys.vmKeys = false
if case .macOS(let why) = route(.volumeUp, noKeys, volume: false) { check(why != nil, "VM without a control socket: volume to macOS, with why") }
else { check(false, "VM without a control socket: volume to macOS, with why") }

// A MacBook Pro (built-in 1, notch) with an external Pi-X9 (2, DDC/CI).
let builtinFull = FrontVM(omacvm: true, fullScreen: true, display: 1, builtin: true, vmKeys: true)
let builtinWin = FrontVM(omacvm: true, fullScreen: false, display: 1, builtin: true, vmKeys: true)
let extFull = FrontVM(omacvm: true, fullScreen: true, display: 2, builtin: false, vmKeys: true)
check(route(.brightnessUp, builtinFull, mac: 1) == .mac, "MacBook full screen: the built-in's brightness, by the Bridge (no macOS popup)")
check(route(.brightnessUp, builtinWin, mac: 1) == .mac, "MacBook windowed on the built-in: the Bridge sets it (macOS's shortcuts are off while the VM has the keyboard)")
check(route(.brightnessUp, extFull, mac: 1, external: .works) == .external(2), "MacBook, VM on the Pi-X9: DDC/CI")
check(route(.brightnessUp, extFull, mac: 1, external: .no("no DDC")) == .macOS("no DDC"), "MacBook, Pi-X9 without DDC: macOS, with why")
check(route(.brightnessUp, extFull, mac: 1, external: .off) != .mac, "MacBook: the built-in is never set for a VM on the external")
check(route(.keyboardUp, builtinFull, light: true) == .mac, "MacBook: Shift+brightness, the keyboard light")
check(route(.volumeUp, builtinWin) == .mac, "MacBook windowed: volume, the Mac's (with the VM's popup)")
// Parallels, UTM, Fusion: full screen only, and no keys typed into them.
let parFull = FrontVM(omacvm: false, fullScreen: true, display: 1, builtin: true, vmKeys: false)
let parWin = FrontVM(omacvm: false, fullScreen: false, display: 1, builtin: true, vmKeys: false)
check(route(.volumeUp, parFull) == .mac && route(.volumeUp, parWin) == .macOS(nil), "Parallels: the Mac's volume in full screen only")
check(route(.play, parFull) == .macOS(nil), "Parallels: play stays as it was (its own)")

var once = OnceLog()
check(once.first("a") && !once.first("a") && once.first("b"), "a reason is logged once")

// ---- QEMU's control socket ----
check(QMPKeys.socketPath(["-name", "Omarchy", "-qmp", "unix:/Users/a/Library/Caches/OmacVM/run/x.qmp,server=on,wait=off"])
      == "/Users/a/Library/Caches/OmacVM/run/x.qmp", "QMP: the socket from the command line")
check(QMPKeys.socketPath(["-qmp", "unix:/tmp/a,,b.qmp,server=on"]) == "/tmp/a,b.qmp", "QMP: a doubled comma is a comma")
check(QMPKeys.socketPath(["-qmp", "tcp:127.0.0.1:4444"]) == nil && QMPKeys.socketPath(["-qmp"]) == nil && QMPKeys.socketPath([]) == nil,
      "QMP: no Unix socket, nothing")
check(QMPKeys.socketPath(["-qmp", "unix:/" + String(repeating: "x", count: 200)]) == nil, "QMP: too long for a socket address")
check(QMPKeys.commands("volumeup").count == 3 && QMPKeys.commands("volumeup")[1].contains(#""down":true"#)
      && QMPKeys.commands("volumeup")[2].contains(#""down":false"#), "QMP: capabilities, down, up")
check(QMPKeys.kind(#"{"QMP": {"version": {}}}"#) == "greeting" && QMPKeys.kind(#"{"return": {}}"#) == "ok"
      && QMPKeys.kind(#"{"error": {"class": "x"}}"#) == "error" && QMPKeys.kind(#"{"event": "RESUME"}"#) == nil
      && QMPKeys.kind("garbage") == nil, "QMP: replies told apart (events skipped)")
func procargs(_ args: [String], exe: String = "/x/OmacVM") -> [UInt8] {
  var b: [UInt8] = [UInt8(args.count), 0, 0, 0] + Array(exe.utf8) + [0, 0, 0]
  for a in args { b += Array(a.utf8) + [0] }
  return b + Array("HOME=/Users/a".utf8) + [0]
}
check(ProcArgs.parse(procargs(["OmacVM", "-qmp", "unix:/s"])) == ["OmacVM", "-qmp", "unix:/s"], "procargs: argv, no environment")
check(ProcArgs.parse([]) == nil && ProcArgs.parse([2, 0, 0, 0, 65, 0, 66]) == nil && ProcArgs.parse([0, 0, 0, 0]) == nil,
      "procargs: short, cut off or empty: nothing")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("models: all ok")
