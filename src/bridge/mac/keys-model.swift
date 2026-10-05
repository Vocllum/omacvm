// When the media-key tap is created again, without AppKit (keys.swift uses it;
// test.sh's offline tests check it). Same rule as the Gestures helper's tap.
import Foundation

/// A new event tap goes to the head of its chain, so a tap made by a VM app
/// started after the Bridge (each OmacVM VM is its own QEMU process) sits
/// ahead of ours. So the tap is created again whenever an OmacVM process comes
/// to the front that was not in front just before: a new VM, a restarted app,
/// or the same VM again after another app.
struct TapRearm {
  private var lastFront: pid_t = 0
  private var failureLogged = false

  /// `vmPid`: the front app's pid when it is an OmacVM process, else nil.
  /// True: create the tap again now.
  mutating func front(_ vmPid: pid_t?) -> Bool {
    defer { lastFront = vmPid ?? 0 }
    guard let vmPid else { return false }
    return vmPid != lastFront
  }

  /// A re-creation failed (Accessibility taken away): true the first time
  /// only, until one works again.
  mutating func failed() -> Bool {
    defer { failureLogged = true }
    return !failureLogged
  }

  mutating func worked() { failureLogged = false }
}

// ---- where a media key goes (keys.swift asks; test-models.sh checks) ----

/// The media keys the Bridge looks at (NX_KEYTYPE_*, IOKit/hidsystem/ev_keymap.h).
enum MediaKey: Int {
  case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
  case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
  case keyboardUp = 21, keyboardDown = 22, keyboardToggle = 23

  /// The key QEMU types for it in the VM (a QKeyCode): XF86AudioRaiseVolume &
  /// co. there, which Omarchy binds to its own volume popup and to playerctl.
  var qcode: String? {
    switch self {
    case .volumeUp: "volumeup"
    case .volumeDown: "volumedown"
    case .mute: "audiomute"
    case .play: "audioplay"
    case .next, .fast: "audionext"   // Apple keyboards send FAST/REWIND for the track keys
    case .previous, .rewind: "audioprev"
    default: nil
    }
  }
}

/// The VM app in front as the key path sees it. `omacvm`: an OmacVM.app VM
/// (also windowed); Parallels, UTM and Fusion count only full screen.
/// `display`: the Mac display it is on, `builtin` whether that is the
/// built-in one. `vmKeys`: keys can be typed into it (OmacVM.app's QMP).
struct FrontVM: Equatable {
  var omacvm: Bool
  var fullScreen: Bool
  var display: UInt32
  var builtin: Bool
  var vmKeys: Bool
}

/// What the Bridge knows about an external display's brightness.
enum ExternalState: Equatable {
  case works        // DDC/CI or the display's own control (Apple displays, LG UltraFine)
  case unknown      // not looked at yet (a look is queued)
  case no(String)   // why not
  case off          // external_brightness off in config.json
}

enum KeyRoute: Equatable {
  case macOS(String?)       // passed on to macOS; the reason is logged once (nil: nothing to say)
  case mac                  // the Bridge sets the Mac's own (volume, mute, keyboard light, its brightness display)
  case external(UInt32)     // that external display's brightness
  case vm(String)           // typed into the VM in front (a QKeyCode)
}

enum MediaRoute {
  /// `vm`: the VM in front, nil for none. `volumeSettable`/`muteSettable`: the
  /// Mac's default output has a software volume/mute (a Scarlett 2i2 has
  /// neither). `macBrightness`: the display the Bridge's own brightness call
  /// sets (the built-in one, else the display macOS dims itself, the main one
  /// first; nil: none). `external`: what is known about the VM's display when
  /// it is external. `keyboardLight`: this Mac has one.
  static func route(_ key: MediaKey, vm: FrontVM?, volumeSettable: Bool, muteSettable: Bool,
                    macBrightness: UInt32?, external: ExternalState, keyboardLight: Bool) -> KeyRoute {
    guard let vm, vm.omacvm || vm.fullScreen else { return .macOS(nil) }   // no VM in front: macOS's keys
    switch key {
    case .volumeUp, .volumeDown, .mute:
      if key == .mute ? muteSettable : volumeSettable { return .mac }
      // No software volume on the Mac's output: the VM's own volume (its
      // popup), never macOS's greyed-out panel.
      if vm.omacvm && vm.vmKeys, let q = key.qcode { return .vm(q) }
      return .macOS(vm.omacvm ? "the VM takes no keys from the Bridge (QEMU's control socket not found)"
                              : "the Mac's output has no volume macOS can set, and only OmacVM.app VMs take keys")
    case .play, .next, .previous, .fast, .rewind:
      // To the VM's players (MPRIS through playerctl), not macOS's Now Playing.
      guard vm.omacvm else { return .macOS(nil) }
      if vm.vmKeys, let q = key.qcode { return .vm(q) }
      return .macOS("the VM takes no keys from the Bridge (QEMU's control socket not found)")
    case .brightnessUp, .brightnessDown:
      if !vm.builtin, external == .works { return .external(vm.display) }
      // The Bridge's own call reaches the VM's display: the built-in one, or a
      // Mac mini's only display that macOS dims itself (LG UltraFine, Studio
      // Display), full screen or not. An OmacVM.app window on the built-in one
      // too: while it has the keyboard, macOS's own shortcuts are off (they go
      // to the VM), so the Bridge sets the brightness itself rather than rely
      // on macOS for it.
      if macBrightness == vm.display && (vm.fullScreen || !vm.builtin || vm.omacvm) { return .mac }
      if vm.builtin { return .macOS(nil) }
      switch external {
      case .no(let why): return .macOS(why)
      case .unknown: return .macOS("not looked at yet (the next press uses it if it can be set)")
      case .off: return .macOS("external brightness is off (external_brightness in config.json)")
      case .works: return .external(vm.display)
      }
    case .keyboardUp, .keyboardDown, .keyboardToggle:
      return keyboardLight ? .mac : .macOS(nil)
    }
  }
}

/// Says each reason once (per display), so a held key is not a log line per press.
struct OnceLog {
  private var said: Set<String> = []
  mutating func first(_ what: String) -> Bool { said.insert(what).inserted }
  mutating func reset() { said = [] }
}

// ---- QEMU's control socket (QMP) of an OmacVM.app VM ----
enum QMPKeys {
  /// The socket from QEMU's command line: "-qmp unix:PATH,server=on,wait=off"
  /// (a comma in the path is written twice). nil: none, or not a Unix socket.
  static func socketPath(_ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "-qmp"), i + 1 < args.count, args[i + 1].hasPrefix("unix:") else { return nil }
    let v = Array(args[i + 1].dropFirst(5))
    var out = "", k = 0
    while k < v.count {
      if v[k] == "," {
        guard k + 1 < v.count, v[k + 1] == "," else { break }
        k += 1
      }
      out.append(v[k]); k += 1
    }
    return out.isEmpty || out.utf8.count > 103 ? nil : out   // sun_path holds 104 bytes
  }

  /// The commands for one key press: capabilities, the key down, the key up.
  static func commands(_ qcode: String) -> [String] {
    func key(_ down: Bool) -> String {
      #"{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":\#(down),"key":{"type":"qcode","data":"\#(qcode)"}}}]}}"#
    }
    return [#"{"execute":"qmp_capabilities"}"#, key(true), key(false)]
  }

  /// One line from QEMU: "greeting", "ok" (a return), "error", or nil for
  /// anything else (an event, which may come in between).
  static func kind(_ line: String) -> String? {
    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    if o["QMP"] != nil { return "greeting" }
    if o["return"] != nil { return "ok" }
    if o["error"] != nil { return "error" }
    return nil
  }
}

/// KERN_PROCARGS2's buffer -> the arguments (argv only, no environment).
/// Untrusted size and content: anything odd gives nil.
enum ProcArgs {
  static func parse(_ b: [UInt8]) -> [String]? {
    guard b.count >= 4 else { return nil }
    let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    guard argc > 0, argc < 4096 else { return nil }
    var i = 4
    while i < b.count, b[i] != 0 { i += 1 }   // the executable's path
    while i < b.count, b[i] == 0 { i += 1 }   // its padding
    var args: [String] = []
    while args.count < argc, i < b.count {
      let start = i
      while i < b.count, b[i] != 0 { i += 1 }
      guard i < b.count else { return nil }
      args.append(String(decoding: b[start..<i], as: UTF8.self))
      i += 1
    }
    return args.count == argc ? args : nil
  }
}
