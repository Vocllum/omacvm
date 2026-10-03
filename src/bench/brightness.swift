// The built-in display's brightness, for power-suite.sh (the same level for
// every run). Uses macOS's DisplayServices, as the brightness keys do.
//   swift brightness.swift          -> current level, 0.0 to 1.0
//   swift brightness.swift 0.5      set it
import CoreGraphics
import Foundation

let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias Set = @convention(c) (UInt32, Float) -> Int32
guard let ds, let g = dlsym(ds, "DisplayServicesGetBrightness"), let s = dlsym(ds, "DisplayServicesSetBrightness") else {
    FileHandle.standardError.write("brightness: DisplayServices not available\n".data(using: .utf8)!); exit(1)
}
let display = CGMainDisplayID()
if CommandLine.arguments.count > 1, let v = Float(CommandLine.arguments[1]) {
    _ = unsafeBitCast(s, to: Set.self)(display, max(0, min(1, v)))
}
var level: Float = 0
_ = unsafeBitCast(g, to: Get.self)(display, &level)
print(String(format: "%.3f", level))
