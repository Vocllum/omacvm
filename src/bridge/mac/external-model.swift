// External display brightness, the parts without hardware: macOS's steps,
// the DDC/CI packets for VCP 0x10 (luminance), and which Mac display a VM
// window or a guest output is on. Compiled into the Bridge and into
// test.sh's offline tests (no AppKit here).
import CoreGraphics
import Foundation

enum BrightnessStep {
  /// macOS's 16 steps on 0...1; fine (Option, Shift+Option) = 64.
  static func next(_ v: Double, up: Bool, fine: Bool) -> Double {
    let steps = fine ? 64.0 : 16.0
    return max(0, min(1, ((v * steps).rounded() + (up ? 1 : -1)) / steps))
  }

  /// A level 0...1 as the monitor's raw value 0...max, and back.
  static func raw(_ v: Double, max m: Int) -> Int { Int((max(0, min(1, v)) * Double(m)).rounded()) }
  static func level(_ raw: Int, max m: Int) -> Double { m > 0 ? max(0, min(1, Double(raw) / Double(m))) : 0 }
  static func percent(_ v: Double) -> Int { Int((max(0, min(1, v)) * 100).rounded()) }
}

/// DDC/CI over I2C (VESA DDC/CI 1.1): the display at 7-bit address 0x37, the
/// host's sub-address 0x51. A packet: 0x80 | length, the payload, a checksum
/// (XOR of 0x6E, 0x51 and every byte before it).
enum DDCPacket {
  static let address: UInt32 = 0x37
  static let subAddress: UInt32 = 0x51
  static let luminance: UInt8 = 0x10

  /// "Get VCP feature" (opcode 0x01).
  static func get(_ code: UInt8) -> [UInt8] { sealed([0x82, 0x01, code]) }

  /// "Set VCP feature" (opcode 0x03), value big-endian.
  static func set(_ code: UInt8, _ value: UInt16) -> [UInt8] {
    sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
  }

  private static func sealed(_ b: [UInt8]) -> [UInt8] { b + [b.reduce(0x6E ^ 0x51, ^)] }

  /// The reply to get: 0x6E, 0x88, 0x02 (VCP reply), result (0 = supported),
  /// the code, type, max (2 bytes), current (2 bytes), checksum (XOR of 0x50
  /// and the bytes before it). nil for anything else: the display is untrusted
  /// input too (a missing answer reads as zeros or 0xFF).
  static func parse(_ r: [UInt8], code: UInt8) -> (current: Int, max: Int)? {
    guard r.count >= 11, r[1] == 0x88, r[2] == 0x02, r[3] == 0x00, r[4] == code,
          r[0..<10].reduce(0x50, ^) == r[10] else { return nil }
    let maximum = Int(r[6]) << 8 | Int(r[7]), current = Int(r[8]) << 8 | Int(r[9])
    guard maximum > 0 else { return nil }
    return (min(current, maximum), maximum)
  }
}

/// A Mac display, in CoreGraphics' global space (points, top-left origin).
struct MacDisplay: Equatable {
  let id: CGDirectDisplayID
  let bounds: CGRect
  let builtin: Bool
}

enum DisplayPick {
  /// A window covering a display: full screen (the menu bar or the notch strip
  /// may stay above it), as the media keys have always checked.
  static func covers(_ w: CGRect, _ d: CGRect) -> Bool {
    abs(w.width - d.width) < 2 && w.height >= d.height - 80 && abs(w.minX - d.minX) < 2 &&
      w.minY >= d.minY - 2 && w.maxY <= d.maxY + 2
  }

  /// The display with most of the window on it.
  static func home(_ w: CGRect, _ displays: [MacDisplay]) -> MacDisplay? {
    var best: MacDisplay?, area: CGFloat = 0
    for d in displays {
      let i = w.intersection(d.bounds)
      if !i.isNull, i.width * i.height > area { best = d; area = i.width * i.height }
    }
    return best
  }

  /// The display of the VM window in front, for the brightness keys and for
  /// a guest request without a box. `windows`: the front VM app's windows,
  /// front to back. Full screen: the display under the pointer when the VM
  /// covers it, else the first one it covers. `windowed` (OmacVM.app, or a
  /// request from the guest): also a window that is not full screen, the one
  /// under the pointer first, else the front window's display.
  static func focused(windows: [CGRect], displays: [MacDisplay], pointer: CGPoint,
                      windowed: Bool) -> (display: MacDisplay, fullScreen: Bool)? {
    let under = displays.first { $0.bounds.contains(pointer) }
    let full = displays.filter { d in windows.contains { covers($0, d.bounds) } }
    if let u = under, full.contains(u) { return (u, true) }
    if let f = windows.lazy.compactMap({ w in full.first { covers(w, $0.bounds) } }).first { return (f, true) }
    guard windowed else { return nil }
    if let u = under, windows.contains(where: { home($0, displays) == u }) { return (u, false) }
    if let w = windows.first, let d = home(w, displays) { return (d, false) }
    return nil
  }

  /// A guest output's box from OmacVM.app's layout (points; the layout's
  /// top-left corner is 0,0) -> the display it is on, among the displays that
  /// show an OmacVM.app window. First by size: the output's window is as wide
  /// as the box and at most a title bar or the notch strip taller (another
  /// VM's windows rarely match). Several left: the layout keeps the Mac's
  /// arrangement, so the box's centre, moved by the top-left corner of their
  /// displays, lands on its display (the notch strip shifts it a little).
  static func forBox(_ box: CGRect, windows: [CGRect], displays: [MacDisplay]) -> MacDisplay? {
    func homes(_ ws: [CGRect]) -> [MacDisplay] {
      var out: [MacDisplay] = []
      for w in ws { if let d = home(w, displays), !out.contains(d) { out.append(d) } }
      return out
    }
    let sized = homes(windows.filter { abs($0.width - box.width) < 2 && (-2...60).contains($0.height - box.height) })
    if sized.count == 1 { return sized[0] }
    let shown = sized.isEmpty ? homes(windows) : sized
    if shown.count == 1 { return shown[0] }
    guard let minX = shown.map({ $0.bounds.minX }).min(), let minY = shown.map({ $0.bounds.minY }).min() else { return nil }
    let p = CGPoint(x: minX + box.midX, y: minY + box.midY)
    return shown.first { $0.bounds.contains(p) }
  }

  /// A box from the guest is untrusted: finite, positive size, within reason.
  static func validBox(_ b: CGRect) -> Bool {
    [b.minX, b.minY, b.width, b.height].allSatisfy { $0.isFinite && abs($0) <= 100_000 } && b.width > 0 && b.height > 0
  }
}
