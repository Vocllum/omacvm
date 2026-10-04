// libFuzzer harness for the camera port's request lines (CameraRequests in
// src/bridge/mac/camera.swift): what a VM sends on its camera connection,
// fed in two pieces like two reads.
import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
  let cut = size > 0 ? Int(data[0]) % (size + 1) : 0
  var r = CameraRequests()
  var n = 0
  if r.feed(UnsafeBufferPointer(start: data, count: cut), want: { _ in n += 1 }) {
    _ = r.feed(UnsafeBufferPointer(start: data + cut, count: size - cut), want: { _ in n += 1 })
  }
  return 0
}
