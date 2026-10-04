// libFuzzer harness for the battery port's line reader (BatteryLines in
// app/app/Sources/OmacVM/NativeBatteryBridge.swift): what a VM sends, cut
// into reads of the size the first byte says.
import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
  guard size > 0 else { return 0 }
  let bytes = Array(UnsafeBufferPointer(start: data + 1, count: size - 1))
  let step = max(1, Int(data[0]) * 32)
  var lines = BatteryLines()
  var i = 0
  while i < bytes.count {
    lines.feed(bytes[i..<min(i + step, bytes.count)]) { line in
      // A line is at most a full read past the limit.
      if line.count > NativeBatteryBridge.maximumLineBytes + 4096 { abort() }
      _ = NativeBatteryBridge.isRefreshRequest(line)
    }
    i += step
  }
  return 0
}
