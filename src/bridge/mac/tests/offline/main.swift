// Offline tests of external-model.swift: steps, DDC/CI packets, which display.
// Built and run by ../../test.sh (no display, no permissions).
import CoreGraphics
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failed += 1; print("FAIL (line \(line)): \(what)") }
}

// ---- steps: macOS's 16 (fine 64), on the grid, clamped ----
check(BrightnessStep.next(0.5, up: true, fine: false) == 9.0 / 16, "0.5 up = 9/16")
check(BrightnessStep.next(0.5, up: false, fine: false) == 7.0 / 16, "0.5 down = 7/16")
check(BrightnessStep.next(0.35, up: true, fine: false) == 7.0 / 16, "off the grid: snaps (0.35 -> 6/16) then steps")
check(BrightnessStep.next(1, up: true, fine: false) == 1, "top stays 1")
check(BrightnessStep.next(0, up: false, fine: false) == 0, "bottom stays 0")
check(BrightnessStep.next(0.5, up: true, fine: true) == 33.0 / 64, "fine: 1/64")
var v = 0.0
for _ in 0..<16 { v = BrightnessStep.next(v, up: true, fine: false) }
check(v == 1, "16 steps from 0 reach 1")
check(BrightnessStep.raw(0.4375, max: 100) == 44, "raw: 7/16 of 100 = 44")
check(BrightnessStep.raw(1.5, max: 100) == 100 && BrightnessStep.raw(-1, max: 100) == 0, "raw clamps")
check(BrightnessStep.level(35, max: 100) == 0.35, "level 35/100")
check(BrightnessStep.level(5, max: 0) == 0, "max 0: level 0, no division")
check(BrightnessStep.percent(0.4375) == 44, "percent rounds")

// ---- DDC/CI packets ----
check(DDCPacket.get(0x10) == [0x82, 0x01, 0x10, 0xAC], "get VCP 0x10 (checksum 0x6E^0x51^...)")
check(DDCPacket.set(0x10, 44) == [0x84, 0x03, 0x10, 0x00, 0x2C, 0x84], "set VCP 0x10 = 44 (checksum 0x84)")
check(Array(DDCPacket.set(0x10, 0x1234)[3...4]) == [0x12, 0x34], "set: big-endian value")
// A real reply (Pi-X9 over USB-C, 2026-10-05): max 100, current 35.
let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x23, 0xe3]
check(DDCPacket.parse(reply, code: 0x10).map { $0 == (35, 100) } == true, "parse a real reply")
var bad = reply; bad[10] ^= 1
check(DDCPacket.parse(bad, code: 0x10) == nil, "wrong checksum refused")
var unsupported = reply; unsupported[3] = 0x01; unsupported[10] ^= 0x01
check(DDCPacket.parse(unsupported, code: 0x10) == nil, "result 'unsupported' refused")
check(DDCPacket.parse([UInt8](repeating: 0, count: 11), code: 0x10) == nil, "no answer (zeros) refused")
check(DDCPacket.parse([UInt8](repeating: 0xFF, count: 11), code: 0x10) == nil, "no answer (0xFF) refused")
check(DDCPacket.parse(Array(reply.prefix(10)), code: 0x10) == nil, "short reply refused")
check(DDCPacket.parse(reply, code: 0x12) == nil, "another VCP code refused")
var zeroMax = reply; zeroMax[7] = 0; zeroMax[10] ^= 0x64
check(DDCPacket.parse(zeroMax, code: 0x10) == nil, "max 0 refused")
var over = reply; over[9] = 0xC8; over[10] = over[0..<10].reduce(0x50, ^)
check(DDCPacket.parse(over, code: 0x10).map { $0 == (100, 100) } == true, "current above max: clamped")

// ---- which display ----
// A MacBook (1728x1117 points, notch) with a 1920x1200 display above it.
let builtin = MacDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), builtin: true)
let external = MacDisplay(id: 4, bounds: CGRect(x: -96, y: -1200, width: 1920, height: 1200), builtin: false)
let displays = [builtin, external]
let fullBuiltin = CGRect(x: 0, y: 38, width: 1728, height: 1079)   // below the notch strip
let fullExternal = CGRect(x: -96, y: -1200, width: 1920, height: 1200)
let windowOnExternal = CGRect(x: 100, y: -1000, width: 1200, height: 800)
let onExternal = CGPoint(x: 500, y: -600), onBuiltin = CGPoint(x: 500, y: 500)

check(DisplayPick.covers(fullBuiltin, builtin.bounds), "full screen below the notch covers the built-in")
check(!DisplayPick.covers(fullBuiltin, external.bounds), "...not the external")
check(DisplayPick.covers(fullExternal, external.bounds), "full screen on the external")
check(!DisplayPick.covers(windowOnExternal, external.bounds), "a window is not full screen")
check(DisplayPick.home(windowOnExternal, displays) == external, "a window's home display")
check(DisplayPick.home(CGRect(x: 5000, y: 5000, width: 10, height: 10), displays) == nil, "off every display: none")

// Full screen on both (Parallels' "all displays", OmacVM.app with external displays): the pointer decides.
let both = [fullBuiltin, fullExternal]
check(DisplayPick.focused(windows: both, displays: displays, pointer: onExternal, windowed: false).map { $0.display == external && $0.fullScreen } == true,
      "full screen on both, pointer on the external: the external")
check(DisplayPick.focused(windows: both, displays: displays, pointer: onBuiltin, windowed: false)?.display == builtin,
      "full screen on both, pointer on the built-in: the built-in")
// Full screen on the external only, pointer elsewhere: still the external.
check(DisplayPick.focused(windows: [fullExternal], displays: displays, pointer: onBuiltin, windowed: false)?.display == external,
      "full screen on the external, pointer on the built-in: the external")
// A window (not full screen): only for OmacVM.app (windowed) or a guest request.
check(DisplayPick.focused(windows: [windowOnExternal], displays: displays, pointer: onExternal, windowed: false) == nil,
      "Parallels/UTM/Fusion windowed: nothing (as before)")
check(DisplayPick.focused(windows: [windowOnExternal], displays: displays, pointer: onBuiltin, windowed: true).map { $0.display == external && !$0.fullScreen } == true,
      "OmacVM.app windowed on the external: the external")
check(DisplayPick.focused(windows: [], displays: displays, pointer: onExternal, windowed: true) == nil, "no window: nothing")

// A guest output's box (OmacVM.app's layout: the outputs' top-left corner at 0,0).
// The built-in's output is its view below the notch; the layout of the two:
let boxExternal = CGRect(x: 0, y: 0, width: 1920, height: 1200)
let boxBuiltin = CGRect(x: 96, y: 1238, width: 1728, height: 1079)
check(DisplayPick.forBox(boxExternal, windows: both, displays: displays) == external, "box of the external output")
check(DisplayPick.forBox(boxBuiltin, windows: both, displays: displays) == builtin, "box of the built-in output")
// Windowed: one window, the box is the window's size at 0,0.
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 1200, height: 800), windows: [windowOnExternal], displays: displays) == external,
      "windowed: the window's display")
check(DisplayPick.forBox(boxExternal, windows: [], displays: displays) == nil, "no OmacVM.app window: nothing")
// External to the right of the built-in, tops aligned.
let right = MacDisplay(id: 5, bounds: CGRect(x: 1728, y: 0, width: 2560, height: 1440), builtin: false)
let ds2 = [builtin, right]
check(DisplayPick.forBox(CGRect(x: 1728, y: 0, width: 2560, height: 1440), windows: [fullBuiltin, right.bounds], displays: ds2) == right,
      "box of an external on the right")
check(DisplayPick.forBox(CGRect(x: 0, y: 38, width: 1728, height: 1079), windows: [fullBuiltin, right.bounds], displays: ds2) == builtin,
      "box of the built-in beside it")

// Boxes from the guest are untrusted.
check(DisplayPick.validBox(boxExternal), "a normal box")
check(!DisplayPick.validBox(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)), "NaN refused")
check(!DisplayPick.validBox(CGRect(x: 0, y: 0, width: 0, height: 10)), "zero width refused")
check(!DisplayPick.validBox(CGRect(x: 1e9, y: 0, width: 10, height: 10)), "far away refused")
check(!DisplayPick.validBox(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)), "infinite refused")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("external brightness: all offline tests passed")
