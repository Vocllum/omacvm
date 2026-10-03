// The Mac's battery, for the VM's bar (UTM and VMware Fusion; OmacVM.app has
// its own copy of this in app/app/Sources/OmacVM/HostBattery.swift, Parallels
// gives the VM a battery itself). Read-only: nothing here changes the Mac.
//   GET /battery, and "battery" events on /events:
//   {"present": true, "percentage": 57, "state": "discharging", "acConnected": false,
//    "timeToEmptySeconds": 8100, "timeToFullSeconds": null, "chargeLimit": 80,
//    "chargeNowMicroAh": 2832900, "chargeFullMicroAh": 4970000,
//    "chargeFullDesignMicroAh": 6075000, "voltageMicroV": 12537000, "cycleCount": 213}
// state: charging, discharging, full, not-charging, unknown. A Mac without a
// battery: present false, percentage null, acConnected true.
//
// From try-omarchy (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
// contributors: macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift
// (HostBatterySnapshot), HostBatteryDetails.swift, HostChargeLimit.swift.
import Foundation
import IOKit
import IOKit.ps

/// One complete snapshot of the Mac's power sources.
struct HostBatterySnapshot: Equatable {
  let present: Bool
  let percentage: Int?
  let state: String
  let acConnected: Bool
  let timeToEmptySeconds: Int?
  let timeToFullSeconds: Int?
  let chargeLimit: Int?
  let details: HostBatteryDetails

  init(descriptions: [[String: Any]], chargeLimit: Int? = nil, details: HostBatteryDetails = HostBatteryDetails()) {
    let internalBattery = descriptions.first {
      $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool != false
    }
    guard let battery = internalBattery else {
      present = false; percentage = nil; state = "unknown"; acConnected = true
      timeToEmptySeconds = nil; timeToFullSeconds = nil; self.chargeLimit = nil; self.details = HostBatteryDetails()
      return
    }
    present = true
    self.details = details
    self.chargeLimit = chargeLimit.flatMap { (1..<100).contains($0) ? $0 : nil }
    let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
    let maximum = battery[kIOPSMaxCapacityKey] as? Int ?? 100
    percentage = maximum > 0 ? min(100, max(0, current * 100 / maximum)) : 0
    let onMains = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    acConnected = onMains
    if battery[kIOPSIsChargingKey] as? Bool == true { state = "charging" }
    else if battery[kIOPSIsChargedKey] as? Bool == true { state = "full" }
    else if onMains { state = "not-charging" }
    else { state = "discharging" }
    func seconds(_ key: String) -> Int? {
      guard let minutes = battery[key] as? Int, minutes >= 0 else { return nil }
      return minutes * 60
    }
    timeToEmptySeconds = state == "discharging" ? seconds(kIOPSTimeToEmptyKey) : nil
    timeToFullSeconds = state == "charging" ? seconds(kIOPSTimeToFullChargeKey) : nil
  }

  var dictionary: [String: Any] {
    [
      "type": "state",
      "present": present,
      "percentage": percentage as Any? ?? NSNull(),
      "state": state,
      "acConnected": acConnected,
      "timeToEmptySeconds": timeToEmptySeconds as Any? ?? NSNull(),
      "timeToFullSeconds": timeToFullSeconds as Any? ?? NSNull(),
      "chargeLimit": chargeLimit as Any? ?? NSNull(),
      "chargeNowMicroAh": details.chargeNowMicroAh as Any? ?? NSNull(),
      "chargeFullMicroAh": details.chargeFullMicroAh as Any? ?? NSNull(),
      "chargeFullDesignMicroAh": details.chargeFullDesignMicroAh as Any? ?? NSNull(),
      "voltageMicroV": details.voltageMicroV as Any? ?? NSNull(),
      "cycleCount": details.cycleCount as Any? ?? NSNull(),
    ]
  }

  static func capture() -> HostBatterySnapshot {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
      return HostBatterySnapshot(descriptions: [])
    }
    let descriptions = list.compactMap {
      IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
    }
    return HostBatterySnapshot(descriptions: descriptions, chargeLimit: HostChargeLimit.capture(),
                               details: HostBatteryDetails.capture())
  }
}

/// The battery's own readings (AppleSmartBattery), apart from the 0-100
/// capacities above: charge in µAh and voltage in µV, as Linux wants them.
struct HostBatteryDetails: Equatable {
  let chargeNowMicroAh: Int?
  let chargeFullMicroAh: Int?
  let chargeFullDesignMicroAh: Int?
  let voltageMicroV: Int?
  let cycleCount: Int?

  init(properties: [String: Any] = [:]) {
    let data = properties["BatteryData"] as? [String: Any] ?? [:]
    func reading(_ candidates: [Any?], multiplier: Int = 1, minimum: Int = 0) -> Int? {
      for candidate in candidates {
        guard let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = candidate as? Int, value >= minimum, value <= Int(Int32.max) / multiplier else { continue }
        return value * multiplier
      }
      return nil
    }
    chargeNowMicroAh = reading([properties["AppleRawCurrentCapacity"], data["RemainingCapacity"]], multiplier: 1000)
    chargeFullMicroAh = reading([properties["AppleRawMaxCapacity"], data["FullChargeCapacity"]], multiplier: 1000, minimum: 1)
    chargeFullDesignMicroAh = reading([properties["DesignCapacity"], data["DesignCapacity"]], multiplier: 1000, minimum: 1)
    voltageMicroV = reading([properties["Voltage"]], multiplier: 1000, minimum: 1)
    cycleCount = reading([properties["CycleCount"]])
  }

  static func capture() -> HostBatteryDetails {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return HostBatteryDetails() }
    defer { IOObjectRelease(service) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let properties = unmanaged?.takeRetainedValue() as? [String: Any],
          properties["BatteryInstalled"] as? Bool != false else { return HostBatteryDetails() }
    return HostBatteryDetails(properties: properties)
  }
}

/// The charge limit set in macOS (System Settings › Battery), read from
/// powerd's file. Undocumented: missing or changed means no limit.
enum HostChargeLimit {
  static let policyURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")

  static func capture() -> Int? {
    guard let data = try? Data(contentsOf: policyURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let archive = plist["policies"] as? Data,
          let decoder = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
    decoder.decodingFailurePolicy = .setErrorAndReturn
    decoder.setClass(HostChargingPolicy.self, forClassName: "ChargeCtrlPolicy")
    defer { decoder.finishDecoding() }
    guard let policies = decoder.decodeObject(of: [NSArray.self, HostChargingPolicy.self, NSString.self],
                                              forKey: NSKeyedArchiveRootObjectKey) as? [HostChargingPolicy],
          decoder.error == nil else { return nil }
    return policies.filter { $0.reason == "manualChargeLimit" && !$0.terminated && (1..<100).contains($0.limit) }
      .map(\.limit).min()
  }
}

@objc(OmacVMHostChargingPolicy)
private final class HostChargingPolicy: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let reason: String?
  let limit: Int
  let terminated: Bool

  required init?(coder: NSCoder) {
    reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
    limit = coder.decodeInteger(forKey: "soclimit")
    terminated = coder.decodeBool(forKey: "terminated")
  }

  func encode(with coder: NSCoder) { preconditionFailure("read-only") }
}

/// Calls back on every change of the Mac's power sources (IOKit), on the main
/// run loop (the Bridge runs it: app.run()).
func watchPowerSources(_ changed: @escaping () -> Void) {
  final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
  let context = Unmanaged.passRetained(Box(changed)).toOpaque()   // lives as long as the app
  guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
    guard let ctx else { return }
    Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().f()
  }, context)?.takeRetainedValue() else {
    log("battery: no IOKit power notifications; read every \(Int(tickSeconds)) s instead")
    return
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
}

/// The Bridge's "battery" state.
func batteryState() -> [String: Any] { HostBatterySnapshot.capture().dictionary }

/// What a change sent at once is about; the battery's own readings
/// (voltage, charge in µAh) move all the time and go out at most every
/// `minorSeconds`.
func coarseBattery(_ s: [String: Any]) -> [String: Any] {
  s.filter { !["voltageMicroV", "chargeNowMicroAh", "timeToEmptySeconds", "timeToFullSeconds"].contains($0.key) }
}

func describeBattery(_ old: [String: Any], _ new: [String: Any]) -> String? {
  guard !same(old["state"], new["state"]) || !same(old["acConnected"], new["acConnected"]) else { return nil }
  guard new["present"] as? Bool == true else { return "no battery" }
  return "\(new["percentage"] as? Int ?? 0) %, \(new["state"] as? String ?? "?")"
}
