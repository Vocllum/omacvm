// A steady Wi-Fi state, without CoreWLAN (wifi.swift reads it; test.sh's
// offline tests check this).
//
// On a Mac mini on Ethernet with Wi-Fi also connected, a read now and then
// came back without a channel or a signal (connected=false, ssid null) and
// the next one was fine again: the Bridge sent "disconnected" and "connected"
// every 5-15 s although Wi-Fi was stable. Such a read is most likely taken
// while the radio scans off its channel (macOS scans more while Wi-Fi is not
// the primary network). A real disconnect comes with a CoreWLAN event (link,
// SSID, BSSID, power) and with the system's link state going down.
import Foundation

struct WiFiSteady {
  /// A lone "not connected" without an event is believed after this long.
  static let hold: TimeInterval = 10
  /// An event this long before the drop still counts as its cause.
  static let eventSlack: TimeInterval = 2
  /// Fields that are no part of the link and always come from the newest read.
  static let fresh = ["location_authorized", "wired"]

  private(set) var good: [String: Any]?   // the last read that was connected
  private var dropSince: Date?

  /// `raw`: one read; `link`: the system's link state of the Wi-Fi interface
  /// (nil: not known); `event`: when CoreWLAN last said link, SSID, BSSID or
  /// power changed. Returns the state to report, and `held` when a "not
  /// connected" read was not believed (yet).
  mutating func take(_ raw: [String: Any], link: Bool?, event: Date?, now: Date) -> (state: [String: Any], held: Bool) {
    if raw["connected"] as? Bool == true { good = raw; dropSince = nil; return (raw, false) }
    guard let good else { return (raw, false) }
    var keep = good
    for k in Self.fresh { keep[k] = raw[k] }
    if link == true { dropSince = nil; return (keep, true) }   // still associated: the read was wrong
    let since = dropSince ?? now
    dropSince = since
    let caused = event.map { $0 >= since - Self.eventSlack } ?? false
    if caused || now.timeIntervalSince(since) >= Self.hold {
      self.good = nil; dropSince = nil
      return (raw, false)
    }
    return (keep, true)
  }
}
