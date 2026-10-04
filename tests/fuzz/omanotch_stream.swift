// libFuzzer harness for Omanotch's frame parser (src/omanotch/mac/Sources/Stream.swift):
// the bytes are the guest's notchcast stream, fed in two pieces.
import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
  let all = Data(bytes: data, count: size)
  let cut = size > 0 ? Int(data[0]) % (size + 1) : 0
  let s = GuestStream()
  do {
    _ = try s.feed(all.subdata(in: 0..<cut))
    _ = try s.feed(all.subdata(in: cut..<size))
    _ = s.makeImage(); _ = s.backgroundColor()
  } catch {}
  return 0
}
