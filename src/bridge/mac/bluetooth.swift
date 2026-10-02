// Bluetooth side: the Mac's paired devices, their battery, connect/disconnect/
// forget and Bluetooth power, pushed as the "bluetooth" feed. The VM has no
// Bluetooth of its own; Omarchy's Bluetooth panel (omacvm.bluetooth) drives the
// Mac's instead.
//
// Two sources: IOBluetooth for live state and the actions (needs the Bluetooth
// permission, which macOS asks for once), and macOS's system report
// (system_profiler SPBluetoothDataType, answered by bluetoothd in ~60 ms, no
// permission) for each device's kind and battery levels, which IOBluetooth
// lacks for Bluetooth LE devices. Without the permission the report alone
// still lists the devices, read-only.
//
// Power and forget have no public API: IOBluetooth's own
// IOBluetoothPreferenceSetControllerPowerState and -[IOBluetoothDevice remove]
// (as blueutil uses them), looked up at run time. When they are missing the
// state says so and the VM opens the Mac's Bluetooth settings instead.
import AppKit
import CoreBluetooth
import IOBluetooth

private typealias SetPower = @convention(c) (Int32) -> Void
private let setPowerFn: SetPower? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOBluetoothPreferenceSetControllerPowerState")
  .map { unsafeBitCast($0, to: SetPower.self) }
private let removeSel = NSSelectorFromString("remove")

// "aa-bb-cc-dd-ee-ff" (IOBluetooth) / "AA:BB:…" (report, BlueZ) -> "AA:BB:CC:DD:EE:FF"
func btAddress(_ s: String) -> String { s.uppercased().replacingOccurrences(of: "-", with: ":") }

func describeBluetooth(_ old: [String: Any], _ s: [String: Any]) -> String? {
  func connected(_ st: [String: Any]) -> [String] {
    ((st["devices"] as? [[String: Any]]) ?? []).filter { $0["connected"] as? Bool == true }.compactMap { $0["name"] as? String }.sorted()
  }
  guard !same(old["power"], s["power"]) || !same(old["permission"], s["permission"]) || connected(old) != connected(s) else { return nil }
  return "power=\(s["power"]!) permission=\(s["permission"]!) connected=\(connected(s))"
}

final class BluetoothBridge: NSObject, CBCentralManagerDelegate {
  private let q = DispatchQueue(label: "omacvm-bridge.bluetooth")   // actions, one at a time
  private let lock = NSLock()
  private var report: (at: Date, power: Bool?, devices: [String: [String: Any]]) = (.distantPast, nil, [:])
  private var reportConnected: Set<String> = []
  private var central: CBCentralManager?
  private var connectNote: IOBluetoothUserNotification?
  private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
  var onChange: ((String) -> Void)?

  var permission: String {
    switch CBCentralManager.authorization {
    case .allowedAlways: "granted"
    case .notDetermined: "not-determined"
    default: "denied"
    }
  }
  private var granted: Bool { CBCentralManager.authorization == .allowedAlways }

  /// Main thread. Asks for the permission once (macOS shows its prompt), then
  /// listens for connections.
  func start() {
    if CBCentralManager.authorization == .notDetermined {
      log("Bluetooth: not decided yet, asking (macOS shows a prompt)")
      NSApp.activate(ignoringOtherApps: true)
    }
    central = CBCentralManager(delegate: self, queue: .main)   // also delivers permission changes
    listen()
  }

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    log("Bluetooth: permission \(permission), state \(c.state.rawValue)")
    listen()
    onChange?("state")
  }

  private func listen() {
    guard granted, connectNote == nil else { return }
    connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    log("Bluetooth: listening for connections")
  }

  @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
    let a = btAddress(device.addressString ?? "")
    disconnectNotes[a]?.unregister()
    disconnectNotes[a] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
    onChange?("connect")
  }

  @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
    disconnectNotes.removeValue(forKey: btAddress(device.addressString ?? ""))?.unregister()
    onChange?("disconnect")
  }

  // ---- macOS's system report: kind, battery, and (without the permission) everything ----
  private func readReport() -> (power: Bool?, devices: [String: [String: Any]]) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (nil, [:]) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return (nil, [:]) }
    let ctl = bt["controller_properties"] as? [String: Any]
    let power = (ctl?["controller_state"] as? String).map { $0 == "attrib_on" }
    var devices: [String: [String: Any]] = [:]
    for (section, isConnected) in [("device_connected", true), ("device_not_connected", false)] {
      for entry in bt[section] as? [[String: Any]] ?? [] {
        for (name, v) in entry {
          guard let info = v as? [String: Any], let addr = info["device_address"] as? String else { continue }
          var battery: [String: Int] = [:]
          for (key, field) in [("main", "device_batteryLevelMain"), ("left", "device_batteryLevelLeft"),
                               ("right", "device_batteryLevelRight"), ("case", "device_batteryLevelCase")] {
            if let s = info[field] as? String, let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) { battery[key] = n }
          }
          devices[btAddress(addr)] = ["name": name, "connected": isConnected,
                                      "kind": kindName(info["device_minorType"] as? String),
                                      "battery": battery.isEmpty ? NSNull() : battery]
        }
      }
    }
    return (power, devices)
  }

  private func kindName(_ minor: String?) -> String {
    switch (minor ?? "").lowercased() {
    case "headphones": "headphones"
    case "headset": "headset"
    case "speaker", "loudspeaker", "portable audio", "hifi audio": "speaker"
    case "keyboard": "keyboard"
    case "mouse": "mouse"
    case "trackpad": "trackpad"
    case "gamepad", "joystick": "gamepad"
    case "phone", "smartphone", "cellular": "phone"
    case "": "other"
    default: (minor ?? "other").lowercased()
    }
  }

  /// The report, re-read when the connected set changed (battery appears),
  /// every minute while something is connected, else every 10 minutes.
  private func cachedReport(connected: Set<String>?) -> (power: Bool?, devices: [String: [String: Any]]) {
    lock.lock(); defer { lock.unlock() }
    let age = Date().timeIntervalSince(report.at)
    let stale = connected.map { $0 != reportConnected } ?? (age > 15)
    if stale || age > (reportConnected.isEmpty ? 600 : 60) {
      let r = readReport()
      report = (Date(), r.power, r.devices)
      reportConnected = connected ?? Set(r.devices.filter { $0.value["connected"] as? Bool == true }.keys)
    }
    return (report.power, report.devices)
  }

  /// The "bluetooth" feed (hub queue).
  func state() -> [String: Any] {
    var s: [String: Any] = ["permission": permission, "power_settable": setPowerFn != nil && granted,
                            "forget_supported": granted && IOBluetoothDevice.instancesRespond(to: removeSel)]
    var devices: [[String: Any]] = []
    if granted {
      let host = IOBluetoothHostController.default()
      s["available"] = host != nil
      s["power"] = host.map { $0.powerState == kBluetoothHCIPowerStateON } ?? false
      let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
      let connected = Set(paired.filter { $0.isConnected() }.map { btAddress($0.addressString ?? "") })
      let meta = cachedReport(connected: connected).devices
      for d in paired {
        let a = btAddress(d.addressString ?? "")
        guard !a.isEmpty else { continue }
        let m = meta[a] ?? [:]
        devices.append(["address": a, "name": d.name ?? (m["name"] as? String) ?? a, "paired": true,
                        "connected": connected.contains(a), "kind": m["kind"] ?? "other",
                        "battery": connected.contains(a) ? (m["battery"] ?? NSNull()) : NSNull()])
      }
    } else {
      let r = cachedReport(connected: nil)
      s["available"] = r.power != nil
      s["power"] = r.power ?? false
      for (a, m) in r.devices {
        devices.append(["address": a, "name": m["name"] ?? a, "paired": true, "connected": m["connected"] ?? false,
                        "kind": m["kind"] ?? "other", "battery": m["battery"] ?? NSNull()])
      }
    }
    s["devices"] = devices.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    return s
  }

  // ---- actions (POST /bluetooth/*) ----
  private func device(_ body: [String: Any]) throws -> IOBluetoothDevice {
    guard granted else { throw APIError(403, "allow Bluetooth for OmacVM Bridge on the Mac (System Settings > Privacy & Security > Bluetooth)") }
    guard let a = body["address"] as? String, a.count == 17 else { throw APIError(400, "send {\"address\": \"AA:BB:CC:DD:EE:FF\"}") }
    let want = btAddress(a)
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    guard let d = paired.first(where: { btAddress($0.addressString ?? "") == want }) else { throw APIError(404, "no paired device \(want)") }
    return d
  }

  func control(_ path: String, _ body: [String: Any]) throws -> String {
    try q.sync {
      switch path {
      case "/bluetooth/power":
        guard granted else { throw APIError(403, "allow Bluetooth for OmacVM Bridge on the Mac (System Settings > Privacy & Security > Bluetooth)") }
        guard let set = setPowerFn else { throw APIError(501, "this macOS has no way to switch Bluetooth for apps: use the Mac's Bluetooth settings") }
        let on = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let want: Bool
        switch body["enabled"] {
        case let b as Bool: want = b
        case let t as String where t == "toggle": want = !on
        default: throw APIError(400, "send {\"enabled\": true|false|\"toggle\"}")
        }
        set(want ? 1 : 0)
        // The controller takes a moment; report once it follows (at most 3 s).
        for _ in 0..<30 where (IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON) != want { usleep(100_000) }
        return "power \(want ? "on" : "off")"
      case "/bluetooth/connect":
        let d = try device(body)
        if d.isConnected() { return "\(d.name ?? "?") already connected" }
        let r = d.openConnection()   // blocks until connected or failed (out of range: ~5-10 s)
        guard r == kIOReturnSuccess else { throw APIError(409, "\(d.name ?? "the device") did not connect (is it on and in range?)") }
        return "connected \(d.name ?? "?")"
      case "/bluetooth/disconnect":
        let d = try device(body)
        guard d.isConnected() else { return "\(d.name ?? "?") not connected" }
        let r = d.closeConnection()
        guard r == kIOReturnSuccess else { throw APIError(409, "\(d.name ?? "the device") did not disconnect") }
        return "disconnected \(d.name ?? "?")"
      case "/bluetooth/forget":
        let d = try device(body)
        guard d.responds(to: removeSel) else { throw APIError(501, "this macOS has no way to forget devices for apps: use the Mac's Bluetooth settings") }
        if d.isConnected() { d.closeConnection() }
        d.perform(removeSel)
        return "forgot \(d.name ?? "?")"
      case "/bluetooth/settings":
        // Pairing needs macOS's own dialog: open its Bluetooth settings.
        DispatchQueue.main.async {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
          NSApp.activate(ignoringOtherApps: true)
        }
        return "opened the Bluetooth settings"
      default:
        throw APIError(404, "not found")
      }
    }
  }
}
