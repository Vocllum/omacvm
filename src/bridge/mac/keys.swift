// Media keys (stage 1c): while a VM is in front (OmacVM.app full screen or in
// a window; Parallels, UTM and Fusion full screen), the volume, brightness and
// keyboard-backlight keys are swallowed (no macOS popup) and applied here
// (Shift + brightness: the keyboard backlight, as in Omarchy); every change,
// ours or not, goes out as an "osd" event so the VM can draw its own popup.
// A Mac output without a software volume (an audio interface such as a
// Scarlett 2i2), and play/pause, next and previous, go into an OmacVM.app VM
// as its own keys (vm-keys.swift). Which key goes where: MediaRoute
// (keys-model.swift). Plus the config file and the menu-bar switch.
import AppKit
import ApplicationServices

// ---- config: ~/Library/Application Support/omacvm-bridge/config.json ----
final class Config {
  let path = supportDir + "/config.json"
  var captureKeys = true       // media keys go to the VM while it is full screen
  var menuBarIcon = true
  var keyboardLowSteps = true  // keyboard light: KeyboardLight.lowSteps below macOS's lowest step

  init() {
    guard let d = FileManager.default.contents(atPath: path),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { save(); return }
    captureKeys = o["capture_keys"] as? Bool ?? captureKeys
    menuBarIcon = o["menu_bar_icon"] as? Bool ?? menuBarIcon
    keyboardLowSteps = o["keyboard_low_steps"] as? Bool ?? keyboardLowSteps
    if o["keyboard_low_steps"] == nil { save() }   // shows the switch in the file
  }

  func save() {
    let o: [String: Any] = ["capture_keys": captureKeys, "menu_bar_icon": menuBarIcon, "keyboard_low_steps": keyboardLowSteps]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
      FileManager.default.createFile(atPath: path, contents: d)
    }
  }
}

func percent(_ v: Float) -> Int { Int((Double(v) * 100).rounded()) }

// ---- display brightness (DisplayServices, private) ----
enum Brightness {
  /// The display get() and set() use (MediaRoute: whether a key on the VM's display may).
  static var displayID: CGDirectDisplayID? { display }

  private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool
  private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
  private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
  private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
  private static let canFn = dlsym(lib, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: Can.self) }

  /// The built-in display; on a Mac without one (or with the lid closed) the
  /// display macOS dims itself (Studio Display, LG UltraFine), the main one
  /// first. nil when there is none.
  private static var display: CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let active = Array(ids.prefix(Int(n)))
    if let d = active.first(where: { CGDisplayIsBuiltin($0) != 0 }) { return d }
    guard let canFn else { return nil }
    let main = CGMainDisplayID()
    return (active.filter { $0 == main } + active.filter { $0 != main }).first { canFn($0) }
  }

  static func get() -> Float? {
    guard let getFn, let d = display else { return nil }
    var v: Float = 0
    return getFn(d, &v) == 0 ? v : nil
  }

  static func set(_ v: Float) -> Bool {
    guard let setFn, let d = display else { return false }
    return setFn(d, max(0, min(1, v))) == 0
  }
}

// ---- keyboard backlight (CoreBrightness KeyboardBrightnessClient, private) ----
enum KeyboardLight {
  private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
  private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
  private typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
  private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
  private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
  private static let client: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
    let c = cls.init()
    return c.responds(to: getSel) && c.responds(to: setSel) ? c : nil
  }()
  private static let keyboard: UInt64? = {
    guard let c = client,
          let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
    let sel = NSSelectorFromString("isKeyboardBuiltIn:")
    let builtIn = c.responds(to: sel) ? unsafeBitCast(c.method(for: sel), to: IsBuiltIn.self) : nil
    return (ids.first { builtIn?(c, sel, $0.uint64Value) ?? true } ?? ids.first)?.uint64Value
  }()
  private static var lastOn: Float = 0.5   // for the toggle key
  /// Below macOS's lowest step (1/16). Measured on a MacBook Pro M4 Max
  /// (macOS 15.7): each value is kept and lights the keys at its own level
  /// (backlightLevelForKeyboard: 0.25, 0.39, 0.68 against 1.01 at 1/16).
  /// Whether the LEDs flicker that low only a person can see:
  /// "keyboard_low_steps": false in config.json switches them off.
  static let lowSteps: [Float] = [0.01, 0.02, 0.04]

  /// The next level up or down: 0, lowSteps, then macOS's 16 steps.
  static func step(_ v: Float, up: Bool, low: Bool) -> Float {
    let levels = [0] + (low ? lowSteps : []) + (1...16).map { Float($0) / 16 }
    return up ? levels.first { $0 > v + 0.001 } ?? 1 : levels.last { $0 < v - 0.001 } ?? 0
  }

  static func get() -> Float? {
    guard let c = client, let k = keyboard else { return nil }
    let v = unsafeBitCast(c.method(for: getSel), to: Get.self)(c, getSel, k)
    return v < 0 ? nil : v
  }

  static func set(_ v: Float) -> Bool {
    guard let c = client, let k = keyboard else { return false }
    if let now = get(), now > 0 { lastOn = now }
    return unsafeBitCast(c.method(for: setSel), to: Set.self)(c, setSel, max(0, min(1, v)), k)
  }

  static func toggle() -> Bool { guard let now = get() else { return false }; return set(now > 0 ? 0 : lastOn) }
}

// ---- "osd" events: {type, kind, value 0-100, muted, source, device} ----
// source: "keys" (caught media key), "api" (POST from the VM), "external"
// (anything else: menu bar, keys outside the VM, AirPods, auto-brightness).
final class OSDEvents {
  private let q = DispatchQueue(label: "omacvm-bridge.osd")
  private var volume: VolumeSnap?
  private var brightness: Int?
  private var brightnessQuietUntil = Date.distantPast
  private var timer: DispatchSourceTimer?
  private var polling = false

  /// The brightness poll runs only while a client asked for external events
  /// (`/events?osd=external`): nothing else uses it.
  func start() {
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
    t.setEventHandler { [self] in pollBrightness() }
    timer = t   // created suspended
    hub.onExternalOSD = { on in self.poll(on) }
    q.async { self.volume = audio.outputSnap() }
  }

  private func poll(_ on: Bool) {
    q.async { [self] in
      guard on != polling, let timer else { return }
      polling = on
      if on { brightness = nil; timer.resume() } else { timer.suspend() }   // a fresh baseline: no stale jump
      log("osd: external brightness changes \(on ? "followed" : "not followed")")
    }
  }

  private func emit(_ kind: String, value: Int?, muted: Bool, source: String, device: String?) {
    hub.send("osd", ["type": "osd", "kind": kind, "value": nn(value), "muted": muted, "source": source,
                     "device": nn(device), "at": isoFormat.string(from: Date())])
  }

  /// We changed the default output's volume or mute.
  func volumeSet(kind: String, source: String) {
    q.async { [self] in
      guard let s = audio.outputSnap() else { return }
      volume = s
      emit(kind, value: s.value, muted: s.muted, source: source, device: s.name)
    }
  }

  /// CoreAudio says something changed; anything we did not set ourselves is external.
  /// Waits a moment so our own volumeSet() lands first.
  func audioChanged() {
    q.asyncAfter(deadline: .now() + 0.15) { [self] in
      let s = audio.outputSnap(), old = volume
      volume = s
      guard let s, let old, s.device == old.device else { return }   // a device switch is no popup
      if s.muted != old.muted { emit("mute", value: s.value, muted: s.muted, source: "external", device: s.name) }
      else if s.value != old.value { emit("volume", value: s.value, muted: s.muted, source: "external", device: s.name) }
    }
  }

  func brightnessSet(source: String) {
    q.async { [self] in
      guard let v = Brightness.get() else { return }
      brightness = percent(v)
      brightnessQuietUntil = Date() + 1   // the panel may ramp; that is not an external change
      emit("brightness", value: brightness, muted: false, source: source, device: "Built-in Display")
    }
  }

  func keyboardSet(source: String) {
    q.async { [self] in
      emit("keyboard", value: KeyboardLight.get().map(percent), muted: false, source: source, device: "Keyboard")
    }
  }

  // No public change notification for brightness: poll, and report jumps of 2+
  // points per half second (keys, slider), not auto-brightness drift.
  private func pollBrightness() {
    guard let v = Brightness.get() else { return }
    let p = percent(v), old = brightness
    brightness = p
    if let old, abs(p - old) >= 2, Date() > brightnessQuietUntil {
      emit("brightness", value: p, muted: false, source: "external", device: "Built-in Display")
    }
  }
}

// ---- media key capture (MediaKey and the rules: keys-model.swift) ----

final class MediaKeys {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var rearm = TapRearm()
  private var askedAX = false
  private let work = DispatchQueue(label: "omacvm-bridge.keys")
  private(set) var vmInFront = false
  private let vmKeys = VMKeys()
  private var once = OnceLog()          // main thread
  private var permissions: String?      // main thread: the last "permissions:" line

  var status: String {
    if !config.captureKeys { return "Media keys: off (macOS handles them)" }
    if tap == nil { return "Media keys: waiting for Accessibility permission" }
    return vmInFront ? "Media keys: going to the VM" : "Media keys: armed (no VM in front)"
  }

  /// Logged at start and whenever one changes; omacvm check reads the last
  /// line. The media keys need Accessibility; Input Monitoring is shown too.
  private func logPermissions() {
    let p = "Accessibility \(AXIsProcessTrusted() ? "granted" : "MISSING"), " +
      "Input Monitoring \(CGPreflightListenEventAccess() ? "granted" : "MISSING")"
    guard p != permissions else { return }
    permissions = p
    log("permissions: \(p)")
  }

  func start() {
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    t.tolerance = 0.5
    RunLoop.main.add(t, forMode: .common)
    // An app switch is checked at once, not up to 2 s later.
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                      object: nil, queue: .main) { [weak self] _ in self?.check() }
    check()
  }

  /// Creates the tap once Accessibility is granted; keeps it enabled, and
  /// creates it again when an OmacVM VM comes to the front (TapRearm) or
  /// macOS invalidated it. Main thread.
  func check() {
    logPermissions()
    let front = NSWorkspace.shared.frontmostApplication
    // An OmacVM.app VM, also when LaunchServices names no executable for QEMU.
    let exe = front.flatMap { $0.executableURL?.path ?? pidPath($0.processIdentifier) } ?? ""
    let isVM = exe.hasSuffix("/runtime/bin/OmacVM") || (exe as NSString).lastPathComponent == "qemu-system-aarch64"
    let vm = isVM ? front?.processIdentifier : nil
    let again = rearm.front(vm)
    guard config.captureKeys else { return }
    if let tap {
      if !CFMachPortIsValid(tap) { install(again: "macOS invalidated it") }
      else if again { install(again: "an OmacVM VM came to the front") }
      else if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): !askedAX] as CFDictionary) {
      if !askedAX { log("media keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)") }
      askedAX = true
      return
    }
    install(again: nil)
  }

  /// The new tap goes in before the old one is removed: no gap without one.
  /// A failed re-creation keeps the old tap and is logged once.
  private func install(again why: String?) {
    let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media/brightness/illumination keys
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
      // check() may create a new tap and invalidate this one: not from inside its own callback.
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { DispatchQueue.main.async { mediaKeys.check() } }
      return mediaKeys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }, userInfo: nil), let s = CFMachPortCreateRunLoopSource(nil, t, 0) else {
      if let why {
        if rearm.failed() { log("media keys: cannot create the event tap again (\(why)); keeping the old one") }
      } else {
        log("media keys: cannot create the event tap although Accessibility is granted; retrying")
      }
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
    if let tap { CFMachPortInvalidate(tap) }
    tap = t
    source = s
    rearm.worked()
    log(why.map { "media keys: event tap created again (\($0))" } ?? "media keys: event tap installed")
  }

  /// The VM app in front and the display it is on: OmacVM.app (its QEMU)
  /// also in a window, Parallels, UTM and VMware Fusion when their VM window
  /// spans a display (below the menu bar or notch strip, so a gap on top).
  private func frontVM() -> (vm: FrontVM, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let exe = app.executableURL?.path ?? pidPath(app.processIdentifier) ?? ""
    let name = (exe as NSString).lastPathComponent
    let omacvm = exe.hasSuffix("/runtime/bin/OmacVM") || name == "qemu-system-aarch64"
    guard omacvm || ["prl_client_app", "UTM", "VMware Fusion"].contains(name),
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let wins: [CGRect] = list.compactMap { w in
      guard w[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier, w[kCGWindowLayer as String] as? Int == 0,
            let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
            r.width > 100, r.height > 100 else { return nil }
      return r
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let displays = ids.prefix(Int(n)).map { ($0, CGDisplayBounds($0)) }
    let pointer = CGEvent(source: nil)?.location ?? .zero
    func spans(_ r: CGRect, _ d: CGRect) -> Bool { abs(r.width - d.width) < 2 && r.height >= d.height - 80 && abs(r.minX - d.minX) < 2 }
    func home(_ r: CGRect) -> CGDirectDisplayID? {
      displays.max { a, b in
        let x = r.intersection(a.1), y = r.intersection(b.1)
        return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
      }.flatMap { r.intersects($0.1) ? $0.0 : nil }
    }
    let full = displays.filter { d in wins.contains { spans($0, d.1) } }
    let under = displays.first { $0.1.contains(pointer) }
    var at: (CGDirectDisplayID, Bool)?
    if let u = under, full.contains(where: { $0.0 == u.0 }) { at = (u.0, true) }
    else if let f = full.first { at = (f.0, true) }
    else if omacvm, let u = under, wins.contains(where: { home($0) == u.0 }) { at = (u.0, false) }
    else if omacvm, let w = wins.first, let d = home(w) { at = (d, false) }
    guard let (display, fullScreen) = at else { return nil }
    let vm = FrontVM(omacvm: omacvm, fullScreen: fullScreen, display: display, builtin: CGDisplayIsBuiltin(display) != 0,
                     vmKeys: omacvm && vmKeys.socket(for: app.processIdentifier) != nil)
    return (vm, app.processIdentifier)
  }

  /// Runs in the tap callback (main thread): true = swallow the event. Where
  /// each key goes: MediaRoute (keys-model.swift).
  func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    guard config.captureKeys, type.rawValue == 14, event.getIntegerValueField(.eventSourceUserData) != VMKeys.marker,
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
    let code = (ns.data1 & 0xFFFF0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0xA
    guard var key = MediaKey(rawValue: code) else { return false }
    let front = frontVM()
    vmInFront = front != nil
    guard let (vm, pid) = front else { return false }   // no VM in front: macOS's keys
    // As in Omarchy: Shift + brightness keys = keyboard backlight (a MacBook has
    // no keys of its own for it), Option + brightness keys = small steps.
    let shift = event.flags.contains(.maskShift), option = event.flags.contains(.maskAlternate)
    if shift && !option {
      if key == .brightnessUp { key = .keyboardUp } else if key == .brightnessDown { key = .keyboardDown }
    }
    // Only what this key needs is asked (CoreAudio, the displays).
    let volume = key == .volumeUp || key == .volumeDown, brightness = key == .brightnessUp || key == .brightnessDown
    let route = MediaRoute.route(key, vm: vm,
                                 volumeSettable: volume && audio.outputVolumeSettable,
                                 muteSettable: key == .mute && audio.outputMuteSettable,
                                 macBrightness: brightness ? Brightness.displayID : nil,
                                 external: .no("the Bridge sets only the display macOS dims itself here"),
                                 keyboardLight: [.keyboardUp, .keyboardDown, .keyboardToggle].contains(key) && KeyboardLight.get() != nil)
    switch route {
    case .macOS(let why):
      // Never swallowed without a word: macOS gets it, and the log says why once.
      if let why, down, once.first("\(key) \(vm.display) \(why)") { log("media key \(key): to macOS: \(why)") }
      return false
    case .external:
      return false   // no external display brightness in this Bridge
    case .mac:
      if down { work.async { self.apply(key, fine: option) } }   // key-up is swallowed too
    case .vm(let qcode):
      guard down else { return true }
      guard let path = vmKeys.socket(for: pid) else { return false }
      work.async {
        let ok = VMKeys.press(qcode, socket: path)
        DispatchQueue.main.async { self.typed(key, into: pid, ok) }
      }
    }
    return true
  }

  /// After a key went to the VM (main thread): the first one per VM is
  /// logged; one that did not go through goes to macOS instead.
  private func typed(_ key: MediaKey, into pid: pid_t, _ ok: Bool) {
    if ok {
      if once.first("typed \(pid)") { log("media keys: typed into the VM (pid \(pid)) through QEMU's control socket, e.g. \(key)") }
      return
    }
    if once.first("untyped \(pid)") { log("media key \(key): the VM did not take it (QEMU's control socket busy or gone): to macOS") }
    VMKeys.repost(key)
  }

  private func apply(_ key: MediaKey, fine: Bool) {
    let steps: Float = fine ? 64 : 16   // macOS: 16 steps, Shift+Option = quarter steps
    func step(_ v: Float, _ up: Bool) -> Float { max(0, min(1, ((v * steps).rounded() + (up ? 1 : -1)) / steps)) }
    var result = "failed"
    switch key {
    case .volumeUp, .volumeDown:
      if let r = try? audio.stepVolume(up: key == .volumeUp, steps: Double(steps)) {
        osdEvents.volumeSet(kind: "volume", source: "keys"); result = "\(r.volume)"
      }
    case .mute:
      if let r = try? audio.setMute(input: false, muted: nil) { osdEvents.volumeSet(kind: "mute", source: "keys"); result = "muted=\(r.muted)" }
    case .brightnessUp, .brightnessDown:
      if let v = Brightness.get(), Brightness.set(step(v, key == .brightnessUp)) {
        osdEvents.brightnessSet(source: "keys"); result = "\(step(v, key == .brightnessUp))"
      }
    case .keyboardUp, .keyboardDown:
      // Option: 1/64 steps as before; else macOS's 1/16 steps and the low ones below.
      if let v = KeyboardLight.get() {
        let to = fine ? step(v, key == .keyboardUp) : KeyboardLight.step(v, up: key == .keyboardUp, low: config.keyboardLowSteps)
        if KeyboardLight.set(to) { osdEvents.keyboardSet(source: "keys"); result = "\(to)" }
      }
    case .keyboardToggle:
      if KeyboardLight.toggle() { osdEvents.keyboardSet(source: "keys"); result = "toggled" }
    case .play, .next, .previous, .fast, .rewind:
      return   // the VM's (MediaRoute), never set here
    }
    log("media key \(key)\(fine ? " (fine)" : "") -> \(result)")
  }
}

// ---- menu bar ----
final class MenuBar: NSObject, NSMenuDelegate {
  private var item: NSStatusItem?
  let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/omacvm-bridge.log").path

  func show() {
    let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    i.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "OmacVM Bridge")
    let menu = NSMenu()
    menu.delegate = self
    i.menu = menu
    item = i
    updateIcon()
  }

  private func updateIcon() { item?.button?.appearsDisabled = !config.captureKeys }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let capture = NSMenuItem(title: "Send Media Keys to the VM in Front", action: #selector(toggleCapture), keyEquivalent: "")
    capture.state = config.captureKeys ? .on : .off
    capture.target = self
    menu.addItem(capture)
    menu.addItem(.separator())
    func info(_ title: String, _ action: Selector? = nil) {
      let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
      m.target = self
      menu.addItem(m)
    }
    info(mediaKeys.status)
    info("Accessibility: " + (AXIsProcessTrusted() ? "granted" : "not granted…"), #selector(openAccessibility))
    info("Location Services: " + (location.authorized ? "granted" : "not granted…"), #selector(openLocation))
    info("Bluetooth: " + (bluetooth.permission == "granted" ? "granted" : "not granted…"), #selector(openBluetooth))
    info("Camera: " + (cameraPermission() == "granted" ? "granted" : cameraPermission() == "not-determined" ? "asked when a VM first uses it" : "not granted…"), #selector(openCamera))
    info("Camera for VMs: \(camera.summary)")
    for s in servers { info(s.status) }
    info("VM event clients: \(hub.clientCount)")
    menu.addItem(.separator())
    info("Open Log", #selector(openLog))
    info("Quit OmacVM Bridge", #selector(quit))
  }

  @objc private func toggleCapture() {
    config.captureKeys.toggle()
    config.save()
    log("media keys: capture \(config.captureKeys ? "ON" : "OFF") (menu)")
    updateIcon()
    mediaKeys.check()
  }

  @objc private func openAccessibility() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  @objc private func openLocation() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
  }

  @objc private func openBluetooth() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
  }

  @objc private func openCamera() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
  }

  @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

  @objc private func quit() { log("quit from the menu bar (starts again at next login)"); exit(0) }
}

/// A process's executable, for an app LaunchServices names no executable for
/// (QEMU makes itself an app without a bundle).
func pidPath(_ pid: pid_t) -> String? {
  var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}
