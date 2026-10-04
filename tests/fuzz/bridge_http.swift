// libFuzzer harness for the Bridge's request head parsing (src/bridge/mac/http.swift):
// the input is a request head as a VM sends it, before the blank line.
import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
  guard let r = parseHead(Data(bytes: data, count: size)) else { return 0 }
  _ = proofNonce(r.query)
  _ = contentLength(r.headers)
  _ = r.query.contains { $0.name == "cached" && $0.value != "0" }
  _ = r.path.hasPrefix("/bluetooth/")
  return 0
}
