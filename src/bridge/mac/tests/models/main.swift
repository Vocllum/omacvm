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

if failed > 0 { print("\(failed) failed"); exit(1) }
print("models: all ok")
