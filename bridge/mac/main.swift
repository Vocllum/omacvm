// omacvm-bridge (Mac side): exposes this Mac's Wi-Fi and audio state to the
// Omarchy VM in Parallels, which only sees a virtual Ethernet NIC and a virtual
// sound card. Wi-Fi is read-only (stage 1); audio can be controlled (stage 1b);
// media keys go to the VM's own popup while it is full screen (stage 1c).
//
// HTTP/1.1 on 10.211.55.2:47831 (Parallels shared network, host side; never
// 0.0.0.0). Every request needs "Authorization: Bearer <token>":
//   GET  /state            Wi-Fi state
//   GET  /scan[?cached=1]  nearby networks, one entry per SSID; cached=1 = the
//                          system's scan cache (instant, no radio scan)
//   GET  /audio            default output/input (volume, mute) + all devices
//   POST /audio/volume     {"volume": 0..1} or {"delta": -1..1}  [+ "scope": "input"]
//   POST /audio/mute       {"muted": true|false|"toggle"}        [+ "scope": "input"]
//   POST /audio/output     {"uid": "<device UID>"}
//   POST /audio/input      {"uid": "<device UID>"}
//   GET  /display          built-in display brightness, Night Shift, True Tone
//   POST /display/brightness   {"brightness": 0..1} or {"delta": -1..1}
//   POST /display/night-shift  {"enabled": true|false|"toggle", "strength": 0..1}
//   POST /display/true-tone    {"enabled": true|false|"toggle"}
//   GET  /wifi/password[?ssid=]  saved password + QR string (macOS asks first)
//   GET  /events           Server-Sent Events: "wifi", "audio" and "display" on every change
//                          (RSSI is re-read every 5 s), "scan" when new scan
//                          results exist, "osd" on volume/mute/brightness/keyboard
//                          light changes (keys.swift), ": ping" every 15 s
// Token: ~/Library/Application Support/omacvm-bridge/token (created on first run).
// SSIDs/BSSIDs are only readable once Location Services is granted to the app.
import AppKit
import Foundation
import Security

setvbuf(stdout, nil, _IOLBF, 0)

let env = ProcessInfo.processInfo.environment
let listenAddr = env["OMACVM_BRIDGE_ADDR"] ?? "10.211.55.2"   // Parallels shared network, host side
let listenPort = UInt16(env["OMACVM_BRIDGE_PORT"] ?? "") ?? 47831
let tickSeconds = 5.0        // RSSI refresh + listener check
let pingSeconds = 15.0       // SSE keepalive when nothing changed
let recentScanSeconds = 10.0 // GET /scan reuses an active scan this young; scan-cache push throttle
let maxClients = 64     // dead connections are only noticed on the next write

let logFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
let isoFormat = ISO8601DateFormatter()

func log(_ s: String) { print("\(logFormat.string(from: Date())) omacvm-bridge: \(s)") }

// ---- token ----
let supportDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/omacvm-bridge").path
let tokenPath = supportDir + "/token"

func loadToken() -> String {
  if let s = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count >= 32 { return t }
  }
  var bytes = [UInt8](repeating: 0, count: 32)
  guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no randomness") }
  let t = bytes.map { String(format: "%02x", $0) }.joined()
  try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
  guard FileManager.default.createFile(atPath: tokenPath, contents: Data((t + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600]) else { fatalError("cannot write \(tokenPath)") }
  log("created token \(tokenPath)")
  return t
}
let token = Array(loadToken().utf8)

// ---- JSON helpers ----
func nn(_ v: Any?) -> Any { v ?? NSNull() }

func jsonData(_ obj: Any) -> Data {
  (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
}

func jsonString(_ obj: Any) -> String { String(decoding: jsonData(obj), as: UTF8.self) }

func same(_ a: Any?, _ b: Any?) -> Bool { jsonData([nn(a)]) == jsonData([nn(b)]) }

// ---- main ----
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let config = Config()

let location = Location()
let wifi = WiFi()
let audio = Audio()
let hub = Hub([
  Feed(event: "wifi", delay: 0.3, read: { wifi.state(locationOK: location.authorized) }, describe: describeWiFi),
  Feed(event: "audio", delay: 0.05, read: { audio.state() }, describe: describeAudio),
  Feed(event: "display", delay: 0.1, read: { displayState() }, describe: describeDisplay),
])
let scanner = Scanner(wifi: wifi, hub: hub, location: location)
let server = Server { fd, peer in handle(fd, peer: peer) }
let osdEvents = OSDEvents()
let mediaKeys = MediaKeys()
let menuBar = MenuBar()

log("starting (pid \(getpid()), token \(tokenPath))")
location.onChange = { hub.changed("wifi", why: "location") }
wifi.onEvent = { why in why == "scan-cache" ? scanner.cacheUpdated() : hub.changed("wifi", why: why) }
audio.onChange = { why in hub.changed("audio", why: why); osdEvents.audioChanged() }
NightShift.onChange { hub.changed("display", why: "night-shift") }
wifi.start()
audio.start()
location.start()
hub.start()
server.check()
osdEvents.start()
mediaKeys.start()
if config.menuBarIcon { menuBar.show() }
log("config \(config.path): capture_keys=\(config.captureKeys) menu_bar_icon=\(config.menuBarIcon)")
let listenerTimer = DispatchSource.makeTimerSource(queue: .main)
listenerTimer.schedule(deadline: .now() + tickSeconds, repeating: tickSeconds)
listenerTimer.setEventHandler { server.check() }
listenerTimer.resume()

let ws = NSWorkspace.shared.notificationCenter
ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in log("system going to sleep") }
ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
  log("system woke up: re-subscribing to CoreWLAN, re-binding listener")
  wifi.subscribe()
  server.check(rebind: true)
  for delay in [2.0, 10.0] {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { hub.changed("wifi", why: "wake"); hub.changed("audio", why: "wake") }
  }
}

app.run()
